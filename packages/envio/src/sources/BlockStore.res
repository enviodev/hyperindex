// Binding to the Rust `BlockStore` napi class. Blocks are kept in Rust as raw
// structs (their large fields never enter JS until read) keyed by block number.
// One store lives per chain on `ChainState`; each fetch response contributes a
// page that is merged in. At batch preparation the selected fields are
// materialised in bulk, off the JS thread, in columnar form and zipped into
// plain JS objects on the main thread.
type t

@send external newEvm: (Core.blockStoreCtor, ~shouldChecksum: bool) => t = "newEvm"
@send external newSvm: Core.blockStoreCtor => t = "newSvm"
@send external newFuel: Core.blockStoreCtor => t = "newFuel"

// The store's ecosystem is fixed here, from the chain's config. EVM carries the
// chain's address-checksumming setting; SVM/Fuel need no extra data.
let make = (~ecosystem: Ecosystem.name, ~shouldChecksum: bool): t => {
  let ctor = Core.getAddon().blockStore
  switch ecosystem {
  | Evm => ctor->newEvm(~shouldChecksum)
  | Svm => ctor->newSvm
  | Fuel => ctor->newFuel
  }
}

// One event's selected block fields → store selection bitmask, built from the
// ecosystem's ordered field-name array (the bit index is the field code shared
// with the Rust store, `EvmBlockField`).
let makeMaskFn = FieldMask.makeMaskFn
let orMask = FieldMask.orMask

// Drain another store (a fetch-response page) into this one.
@send external merge: (t, t) => unit = "merge"

// Bulk-materialise blocks off the JS thread, one row per `blockNumbers[i]` key,
// decoding only the fields set in that row's own `masks[i]`. Result is aligned
// with the input.
@send
external materialize: (
  t,
  ~blockNumbers: array<int>,
  ~masks: array<float>,
) => promise<array<Internal.eventBlock>> = "materialize"

// Drop blocks at or below the given block (already processed).
@send external prune: (t, int) => unit = "prune"

// Drop blocks above the given block (rolled back).
@send external rollback: (t, int) => unit = "rollback"

// Merge a materialised field bag onto an existing block object in place. Used by
// the SVM path, where the source already attached a minimal inline block.
let enrichBlock: (Internal.eventBlock, Internal.eventBlock) => unit = %raw(`(block, fields) => {
    Object.assign(block, fields)
  }`)

// Group adjacent store-backed items into runs sharing a block number, OR-ing
// their block-field masks. Items arrive in (block, logIndex) order, so events
// sharing a block are adjacent; extending the current run avoids hashing a key
// per item. `owns` selects which items this pass materialises (EVM: those with no
// inline block; SVM: those carrying one). Each run's event items are returned for
// the caller to apply the materialised block onto.
let groupByBlock = (items: array<Internal.item>, ~owns: Internal.eventItem => bool): (
  array<int>,
  array<float>,
  array<array<Internal.eventItem>>,
) => {
  let blockNumbers = []
  let masks = []
  let groups = []
  items->Array.forEach(item =>
    switch item {
    | Internal.Event(_) =>
      let eventItem = item->Internal.castUnsafeEventItem
      if owns(eventItem) {
        let {blockNumber} = eventItem
        let mask = eventItem.eventConfig.blockFieldMask
        let last = groups->Array.length - 1
        if last >= 0 && blockNumbers->Array.getUnsafe(last) == blockNumber {
          groups->Array.getUnsafe(last)->Array.push(eventItem)
          masks->Array.setUnsafe(last, orMask(masks->Array.getUnsafe(last), mask))
        } else {
          blockNumbers->Array.push(blockNumber)
          masks->Array.push(mask)
          groups->Array.push([eventItem])
        }
      }
    | Internal.Block(_) => ()
    }
  )
  (blockNumbers, masks, groups)
}

// EVM: materialise each store-backed item's selected block fields and write the
// resulting block onto its payload. Items that already carry an inline block
// (RPC/simulate/Fuel) are skipped. The config's field selection always includes
// number/timestamp/hash, so every mask has bits set and every store-backed item
// gets a block carrying at least the trio. Deduped per block number.
let materializeEvmItems = async (store: t, ~items: array<Internal.item>) => {
  let (blockNumbers, masks, groups) =
    items->groupByBlock(~owns=eventItem =>
      eventItem.payload->Internal.getPayloadBlock->Nullable.toOption->Option.isNone
    )
  if groups->Utils.Array.notEmpty {
    let blocks = await store->materialize(~blockNumbers, ~masks)
    groups->Array.forEachWithIndex((group, i) => {
      let block = blocks->Array.getUnsafe(i)
      group->Array.forEach(ei => ei.payload->Internal.setPayloadBlock(block))
    })
  }
}

// SVM: the source stamps the always-available `slot`/`time`/`hash` inline on
// each item. Enrich each item's block in place with its selected fields from the
// store — a slot missing from the store (no block row, or only inline fields
// selected) yields an empty bag and the inline block stands. Grouped per slot so
// the store is consulted once per slot.
let materializeSvmItems = async (store: t, ~items: array<Internal.item>) => {
  let (blockNumbers, masks, groups) =
    items->groupByBlock(~owns=eventItem =>
      eventItem.payload->Internal.getPayloadBlock->Nullable.toOption->Option.isSome
    )

  // Skip the store call when no instruction selected a block field at all.
  if masks->Array.some(mask => mask !== 0.) {
    let materialized = await store->materialize(~blockNumbers, ~masks)
    groups->Array.forEachWithIndex((group, i) => {
      let fields = materialized->Array.getUnsafe(i)
      group->Array.forEach(eventItem =>
        switch eventItem.payload->Internal.getPayloadBlock->Nullable.toOption {
        | Some(block) => block->enrichBlock(fields)
        | None => ()
        }
      )
    })
  }
}
