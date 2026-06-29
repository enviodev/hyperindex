// Binding to the Rust `TransactionStore` napi class. Transactions are kept in
// Rust as raw structs (their large fields never enter JS until read) keyed by
// (blockNumber, transactionIndex). One store lives per chain on `ChainState`;
// each fetch response contributes a page that is merged in. At batch
// preparation the selected fields are materialised in bulk, off the JS thread,
// in columnar form and zipped into plain JS objects on the main thread.
type t

@send external classNew: Core.transactionStoreCtor => t = "new"
let make = (): t => Core.getAddon().transactionStore->classNew

// Field-name → bit-index map from an ordered field-name array. The index is the
// field code shared with the Rust store (`EvmTxField`/`SvmTxField`).
let fieldCodes = (fields: array<string>): dict<int> => {
  let codes = Dict.make()
  fields->Array.forEachWithIndex((name, i) => codes->Dict.set(name, i))
  codes
}

let pow2: int => float = %raw(`c => Math.pow(2, c)`)

// One event's selected transaction fields as a bitmask float (bit `code` set ⇔
// selected). A field appears at most once, so summing `pow2(code)` is exact and
// dodges 32-bit JS bitwise ops.
let maskFromFields = (selectedTransactionFields: Utils.Set.t<string>, ~codes: dict<int>): float => {
  let mask = ref(0.)
  selectedTransactionFields->Utils.Set.forEach(name =>
    switch codes->Utils.Dict.dangerouslyGetNonOption(name) {
    | Some(code) => mask := mask.contents +. pow2(code)
    | None => ()
    }
  )
  mask.contents
}

// Build an ecosystem's per-event mask function from its ordered field-name
// array. The field codes are derived once and closed over.
let makeMaskFn = (fields: array<string>): (Utils.Set.t<string> => float) => {
  let codes = fieldCodes(fields)
  selectedTransactionFields => selectedTransactionFields->maskFromFields(~codes)
}

// Bitwise OR of two per-event masks. Masks fit in 32 bits (≤32 transaction
// fields), so `>>> 0` recovers the unsigned value that a plain `|` renders
// negative once bit 31 is set.
let orMask: (float, float) => float = %raw(`(a, b) => (a | b) >>> 0`)

// Drain another store (a fetch-response page) into this one.
@send external merge: (t, t) => unit = "merge"

// Bulk-materialise transactions off the JS thread, one row per
// (blockNumbers[i], transactionIndices[i]) key, decoding only the fields set in
// that row's own masks[i]. Result is aligned with the input.
@send
external materialize: (
  t,
  ~blockNumbers: array<int>,
  ~transactionIndices: array<int>,
  ~masks: array<float>,
) => promise<array<Internal.eventTransaction>> = "materialize"

// Drop transactions for blocks at or below the given block (already processed).
@send external prune: (t, int) => unit = "prune"

// Drop transactions for blocks above the given block (rolled back).
@send external rollback: (t, int) => unit = "rollback"

// Materialise each store-backed item's selected transaction fields and write the
// resulting transaction onto its payload. Every event's mask comes from its own
// `eventConfig.transactionFieldMask`, so a transaction decodes only the fields
// the events on it selected — a large field (e.g. `input`) never materialises
// for events that didn't ask for it. Items that already carry an inline
// transaction (RPC/simulate/Fuel) are skipped. Store-backed items always get a
// transaction object — the selected fields, or `{}` when nothing was selected —
// so `event.transaction` is never `undefined` (matching the inline sources).
// Deduped per (blockNumber, transactionIndex); each row's mask is the OR of the
// masks of the events sharing that transaction.
let materializeItems = async (store: t, ~items: array<Internal.item>) => {
  // Store-backed items arrive in (block, logIndex) order, and a transaction's
  // logs are contiguous within a block, so events sharing a (blockNumber,
  // transactionIndex) are adjacent regardless of event. Group them by extending
  // the current run rather than hashing a string key per item. A key recurring
  // non-adjacently just splits into two groups (one redundant decode) — never
  // incorrect.
  let blockNumbers = []
  let transactionIndices = []
  let masks = []
  let payloadGroups = []
  let anySelected = ref(false)

  items->Array.forEach(item =>
    switch item {
    | Internal.Event(_) =>
      let eventItem = item->Internal.castUnsafeEventItem
      switch eventItem.payload->Internal.getPayloadTransaction->Nullable.toOption {
      | Some(_) => () // RPC/simulate/Fuel carry the transaction inline.
      | None =>
        let {blockNumber, transactionIndex} = eventItem
        let mask = eventItem.eventConfig.transactionFieldMask
        if mask != 0. {
          anySelected := true
        }
        let last = payloadGroups->Array.length - 1
        if (
          last >= 0 &&
          blockNumbers->Array.getUnsafe(last) == blockNumber &&
          transactionIndices->Array.getUnsafe(last) == transactionIndex
        ) {
          payloadGroups->Array.getUnsafe(last)->Array.push(eventItem.payload)
          masks->Array.setUnsafe(last, orMask(masks->Array.getUnsafe(last), mask))
        } else {
          blockNumbers->Array.push(blockNumber)
          transactionIndices->Array.push(transactionIndex)
          masks->Array.push(mask)
          payloadGroups->Array.push([eventItem.payload])
        }
      }
    | Internal.Block(_) => ()
    }
  )

  if payloadGroups->Utils.Array.notEmpty {
    if anySelected.contents {
      let txs = await store->materialize(~blockNumbers, ~transactionIndices, ~masks)
      payloadGroups->Array.forEachWithIndex((payloads, i) => {
        let tx = txs->Array.getUnsafe(i)
        payloads->Array.forEach(payload => payload->Internal.setPayloadTransaction(tx))
      })
    } else {
      // No event selected any field: stamp an empty transaction object so
      // `event.transaction` is never undefined, without a materialize call.
      payloadGroups->Array.forEach(payloads =>
        payloads->Array.forEach(payload => payload->Internal.setPayloadTransaction(%raw(`{}`)))
      )
    }
  }
}
