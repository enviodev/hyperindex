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
// `getSelectedFields` extracts the selected field names from each event config.
let mask = (
  eventConfigs: array<Internal.eventConfig>,
  ~codes: dict<int>,
  ~getSelectedFields: Internal.eventConfig => Utils.Set.t<string>,
): float => {
  let selected = Utils.Set.make()
  eventConfigs->Array.forEach(eventConfig =>
    eventConfig
    ->getSelectedFields
    ->Utils.Set.forEach(name =>
      switch codes->Utils.Dict.dangerouslyGetNonOption(name) {
      | Some(code) => selected->Utils.Set.add(code)->ignore
      | None => ()
      }
    )
  )
  selected->Utils.Set.toArray->Array.reduce(0., (mask, code) => mask +. pow2(code))
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
// inline transaction (RPC/simulate/Fuel) are skipped, so a zero mask with no
// store-backed items costs nothing. Deduped per (blockNumber, transactionIndex).
let materializeItems = async (store: t, ~items: array<Internal.item>, ~mask: float) => {
  // No selected transaction fields ⇒ no transaction is wanted on this chain;
  // leave payloads untouched (rather than stamping an empty object).
  if mask != 0. {
    let keys = []
    let blockNumbers = []
    let transactionIndices = []
    let payloadsByKey = Dict.make()

    items->Array.forEach(item =>
      switch item {
      | Internal.Event(_) =>
        let eventItem = item->Internal.castUnsafeEventItem
        switch eventItem.payload->Internal.getPayloadTransaction->Nullable.toOption {
        | Some(_) => ()
        | None =>
          let key =
            eventItem.blockNumber->Int.toString ++ ":" ++ eventItem.transactionIndex->Int.toString
          switch payloadsByKey->Utils.Dict.dangerouslyGetNonOption(key) {
          | Some(payloads) => payloads->Array.push(eventItem.payload)
          | None =>
            keys->Array.push(key)
            blockNumbers->Array.push(eventItem.blockNumber)
            transactionIndices->Array.push(eventItem.transactionIndex)
            payloadsByKey->Dict.set(key, [eventItem.payload])
          }
        }
      | Internal.Block(_) => ()
      }
    )

    if keys->Utils.Array.notEmpty {
      let txs = await store->materialize(~blockNumbers, ~transactionIndices, ~mask)
      keys->Array.forEachWithIndex((key, i) => {
        let tx = txs->Array.getUnsafe(i)
        payloadsByKey
        ->Dict.getUnsafe(key)
        ->Array.forEach(payload => payload->Internal.setPayloadTransaction(tx))
      })
    }
  }
}
