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

// Union of an ecosystem's selected transaction fields as a bitmask float (bit
// `code` set ⇔ selected). Built arithmetically to dodge 32-bit JS bitwise ops.
let mask = (eventConfigs: array<Internal.eventConfig>, ~codes: dict<int>): float => {
  let selected = Utils.Set.make()
  eventConfigs->Array.forEach(eventConfig =>
    eventConfig.selectedTransactionFields->Utils.Set.forEach(name =>
      switch codes->Utils.Dict.dangerouslyGetNonOption(name) {
      | Some(code) => selected->Utils.Set.add(code)->ignore
      | None => ()
      }
    )
  )
  selected->Utils.Set.toArray->Array.reduce(0., (mask, code) => mask +. pow2(code))
}

// Build an ecosystem's mask function from its ordered field-name array. The
// field codes are derived once and closed over.
let makeMaskFn = (fields: array<string>): (array<Internal.eventConfig> => float) => {
  let codes = fieldCodes(fields)
  eventConfigs => eventConfigs->mask(~codes)
}

// Drain another store (a fetch-response page) into this one.
@send external merge: (t, t) => unit = "merge"

// Bulk-materialise the fields selected by `mask` (one bit per field code) for
// the given transactions, off the JS thread. Result is aligned with the input.
@send
external materialize: (
  t,
  ~blockNumbers: array<int>,
  ~transactionIndices: array<int>,
  ~mask: float,
) => promise<array<Internal.eventTransaction>> = "materialize"

// Drop transactions for blocks at or below the given block (already processed).
@send external prune: (t, int) => unit = "prune"

// Drop transactions for blocks above the given block (rolled back).
@send external rollback: (t, int) => unit = "rollback"

// Materialise the mask-selected fields for the store-backed items and write the
// resulting transaction onto each item's payload. Items that already carry an
// inline transaction (RPC/simulate/Fuel) are skipped. Store-backed items always
// get a transaction object — the selected fields, or `{}` when the chain
// selected none — so `event.transaction` is never `undefined` (matching the
// inline sources). Deduped per (blockNumber, transactionIndex).
let materializeItems = async (store: t, ~items: array<Internal.item>, ~mask: float) => {
  if mask == 0. {
    // No fields selected: there's nothing to decode and no reason to group by
    // key, but each store-backed item still gets an empty transaction object so
    // `event.transaction` is never undefined (matching the inline sources).
    items->Array.forEach(item =>
      switch item {
      | Internal.Event(_) =>
        let payload = (item->Internal.castUnsafeEventItem).payload
        switch payload->Internal.getPayloadTransaction->Nullable.toOption {
        | Some(_) => () // RPC/simulate/Fuel carry the transaction inline.
        | None => payload->Internal.setPayloadTransaction(%raw(`{}`))
        }
      | Internal.Block(_) => ()
      }
    )
  } else {
    // Store-backed items arrive in (block, logIndex) order, and a transaction's
    // logs are contiguous within a block, so events sharing a (blockNumber,
    // transactionIndex) are adjacent. Group them by extending the current run
    // rather than hashing a string key per item. A key recurring non-adjacently
    // just splits into two groups (one redundant decode) — never incorrect.
    let blockNumbers = []
    let transactionIndices = []
    let payloadGroups = []

    items->Array.forEach(item =>
      switch item {
      | Internal.Event(_) =>
        let eventItem = item->Internal.castUnsafeEventItem
        switch eventItem.payload->Internal.getPayloadTransaction->Nullable.toOption {
        | Some(_) => () // RPC/simulate/Fuel carry the transaction inline.
        | None =>
          let {blockNumber, transactionIndex} = eventItem
          let last = payloadGroups->Array.length - 1
          if (
            last >= 0 &&
            blockNumbers->Array.getUnsafe(last) == blockNumber &&
            transactionIndices->Array.getUnsafe(last) == transactionIndex
          ) {
            payloadGroups->Array.getUnsafe(last)->Array.push(eventItem.payload)
          } else {
            blockNumbers->Array.push(blockNumber)
            transactionIndices->Array.push(transactionIndex)
            payloadGroups->Array.push([eventItem.payload])
          }
        }
      | Internal.Block(_) => ()
      }
    )

    if payloadGroups->Utils.Array.notEmpty {
      let txs = await store->materialize(~blockNumbers, ~transactionIndices, ~mask)
      payloadGroups->Array.forEachWithIndex((payloads, i) => {
        let tx = txs->Array.getUnsafe(i)
        payloads->Array.forEach(payload => payload->Internal.setPayloadTransaction(tx))
      })
    }
  }
}
