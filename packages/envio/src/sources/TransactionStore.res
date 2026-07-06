// Binding to the Rust `TransactionStore` napi class. Transactions are kept in
// Rust as raw structs (their large fields never enter JS until read) keyed by
// (blockNumber, transactionIndex). One store lives per chain on `ChainState`;
// each fetch response contributes a page that is merged in. At batch
// preparation the selected fields are materialised in bulk, off the JS thread,
// in columnar form and zipped into plain JS objects on the main thread.
type t

@send external newEvm: (Core.transactionStoreCtor, ~shouldChecksum: bool) => t = "newEvm"
@send external newSvm: Core.transactionStoreCtor => t = "newSvm"
@send external newFuel: Core.transactionStoreCtor => t = "newFuel"

// The store's ecosystem is fixed here, from the chain's config. EVM carries the
// chain's address-checksumming setting; SVM/Fuel need no extra data.
let make = (~ecosystem: Ecosystem.name, ~shouldChecksum: bool): t => {
  let ctor = Core.getAddon().transactionStore
  switch ecosystem {
  | Evm => ctor->newEvm(~shouldChecksum)
  | Svm => ctor->newSvm
  | Fuel => ctor->newFuel
  }
}

// One event's selected transaction fields → store selection bitmask, built from
// the ecosystem's ordered field-name array (the bit index is the field code
// shared with the Rust store, `EvmTxField`/`SvmTxField`).
let makeMaskFn = FieldMask.makeMaskFn
let orMask = FieldMask.orMask
let fieldCodes = FieldMask.fieldCodes

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
  // transactionIndex) are adjacent regardless of event.
  let (keys, masks, groups) =
    items->FieldMask.groupAdjacent(
      ~hasInline=payload =>
        payload->Internal.getPayloadTransaction->Nullable.toOption->Option.isSome,
      ~key=eventItem => (eventItem.blockNumber, eventItem.transactionIndex),
      ~sameKey=((blockNumber1, transactionIndex1), (blockNumber2, transactionIndex2)) =>
        blockNumber1 == blockNumber2 && transactionIndex1 == transactionIndex2,
      ~mask=eventItem => eventItem.eventConfig.transactionFieldMask,
    )

  if groups->Utils.Array.notEmpty {
    if masks->Array.some(mask => mask != 0.) {
      let blockNumbers = keys->Array.map(((blockNumber, _)) => blockNumber)
      let transactionIndices = keys->Array.map(((_, transactionIndex)) => transactionIndex)
      let txs = await store->materialize(~blockNumbers, ~transactionIndices, ~masks)
      groups->Array.forEachWithIndex((group, i) => {
        let tx = txs->Array.getUnsafe(i)
        group->Array.forEach(eventItem => eventItem.payload->Internal.setPayloadTransaction(tx))
      })
    } else {
      // No event selected any field: stamp an empty transaction object so
      // `event.transaction` is never undefined, without a materialize call.
      groups->Array.forEach(group =>
        group->Array.forEach(eventItem =>
          eventItem.payload->Internal.setPayloadTransaction(%raw(`{}`))
        )
      )
    }
  }
}
