// Binding to the Rust `TransactionStore` napi class. Transactions are kept in
// Rust as raw structs (their large fields never enter JS until read) keyed by
// (blockNumber, transactionId). One store lives per chain on `ChainState`; each
// fetch response contributes a page that is merged in. At batch preparation the
// selected fields are materialised in bulk, asynchronously, off the JS thread.
type t

@send external classNew: Core.transactionStoreCtor => t = "new"
let make = (): t => Core.getAddon().transactionStore->classNew

// Drain another store (a fetch-response page) into this one.
@send external merge: (t, t) => unit = "merge"

// Bulk-materialise the fields selected by `mask` (one bit per field code) for
// the given transactions, off the JS thread. Result is aligned with the input.
@send
external materialize: (
  t,
  ~blockNumbers: array<int>,
  ~transactionIds: array<string>,
  ~mask: float,
) => promise<array<Internal.eventTransaction>> = "materialize"

// Drop transactions for blocks at or below the given block (already processed).
@send external prune: (t, int) => unit = "prune"

// Drop transactions for blocks above the given block (rolled back).
@send external rollback: (t, int) => unit = "rollback"

// Materialise the mask-selected fields for the store-backed items and write the
// resulting transaction onto each item's payload. Items that already carry an
// inline transaction (RPC/simulate/Fuel/SVM) are skipped, so a zero mask with
// no store-backed items costs nothing. Deduped per (blockNumber, transactionId).
let materializeItems = async (store: t, ~items: array<Internal.item>, ~mask: float) => {
  let keys = []
  let blockNumbers = []
  let transactionIds = []
  let payloadsByKey = Dict.make()

  items->Array.forEach(item =>
    switch item {
    | Internal.Event(_) =>
      let eventItem = item->Internal.castUnsafeEventItem
      switch eventItem.payload->Internal.getPayloadTransaction->Nullable.toOption {
      | Some(_) => ()
      | None =>
        let key = eventItem.blockNumber->Int.toString ++ ":" ++ eventItem.transactionId
        switch payloadsByKey->Utils.Dict.dangerouslyGetNonOption(key) {
        | Some(payloads) => payloads->Array.push(eventItem.payload)
        | None =>
          keys->Array.push(key)
          blockNumbers->Array.push(eventItem.blockNumber)
          transactionIds->Array.push(eventItem.transactionId)
          payloadsByKey->Dict.set(key, [eventItem.payload])
        }
      }
    | Internal.Block(_) => ()
    }
  )

  if keys->Utils.Array.notEmpty {
    let txs = await store->materialize(~blockNumbers, ~transactionIds, ~mask)
    keys->Array.forEachWithIndex((key, i) => {
      let tx = txs->Array.getUnsafe(i)
      payloadsByKey
      ->Dict.getUnsafe(key)
      ->Array.forEach(payload => payload->Internal.setPayloadTransaction(tx))
    })
  }
}
