// Binding to the Rust `BlockStore` napi class. Blocks are kept in Rust as raw
// structs (their large fields never enter JS until read) keyed by block number.
// One store lives per chain on `ChainState`; each fetch response contributes a
// page that is merged in. At batch preparation the selected fields are
// materialised in bulk, off the JS thread, in columnar form and zipped into
// plain JS objects on the main thread.
type t

@send external classNew: Core.blockStoreCtor => t = "new"
let make = (): t => Core.getAddon().blockStore->classNew

// One event's selected block fields → store selection bitmask, built from the
// ecosystem's ordered field-name array (the bit index is the field code shared
// with the Rust store, `EvmBlockField`).
let makeMaskFn = FieldMask.makeMaskFn
let orMask = FieldMask.orMask

// `number`/`timestamp`/`hash` (field codes 0/1/2) are always stamped onto
// `event.block` from the item itself, so a block whose events selected only
// these needs no store lookup. `hasExtraFields` is true once any other field is
// selected — only then is a materialise call worthwhile.
let hasExtraFields: float => bool = %raw(`m => ((m & ~7) >>> 0) !== 0`)

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

// Stamp the always-present trio onto a block object. Taken from the item rather
// than the store so it's correct even when the block was never stored (an event
// that selected only the trio).
let setBlockHeader: (
  Internal.eventBlock,
  ~number: int,
  ~timestamp: int,
  ~hash: string,
) => unit = %raw(`(b, number, timestamp, hash) => {
    b.number = number
    b.timestamp = timestamp
    b.hash = hash
  }`)

// Merge a materialised field bag onto an existing block object in place. Used by
// the SVM path, where the source already attached a minimal inline block.
let enrichBlock: (Internal.eventBlock, Internal.eventBlock) => unit = %raw(`(block, fields) => {
    Object.assign(block, fields)
  }`)

// EVM: materialise each store-backed item's selected block fields and write the
// resulting block onto its payload. Items that already carry an inline block
// (RPC/simulate/Fuel) are skipped. Store-backed items always get a block object
// carrying at least number/timestamp/hash (stamped from the item), plus any
// further fields their events selected. Deduped per block number; each block's
// mask is the OR of the masks of the events sharing it.
let materializeEvmItems = async (store: t, ~items: array<Internal.item>) => {
  // Store-backed items arrive in (block, logIndex) order, so events sharing a
  // block are adjacent. Group them by extending the current run rather than
  // hashing a key per item.
  let blockNumbers = []
  let masks = []
  let payloadGroups = []
  // (number, timestamp, hash) per group, from the group's first item.
  let headers = []
  let anyExtra = ref(false)

  items->Array.forEach(item =>
    switch item {
    | Internal.Event(_) =>
      let eventItem = item->Internal.castUnsafeEventItem
      switch eventItem.payload->Internal.getPayloadBlock->Nullable.toOption {
      | Some(_) => () // RPC/simulate/Fuel carry the block inline.
      | None =>
        let {blockNumber} = eventItem
        let mask = eventItem.eventConfig.blockFieldMask
        if hasExtraFields(mask) {
          anyExtra := true
        }
        let last = payloadGroups->Array.length - 1
        if last >= 0 && blockNumbers->Array.getUnsafe(last) == blockNumber {
          payloadGroups->Array.getUnsafe(last)->Array.push(eventItem.payload)
          masks->Array.setUnsafe(last, orMask(masks->Array.getUnsafe(last), mask))
        } else {
          blockNumbers->Array.push(blockNumber)
          masks->Array.push(mask)
          payloadGroups->Array.push([eventItem.payload])
          headers->Array.push((blockNumber, eventItem.timestamp, eventItem.blockHash))
        }
      }
    | Internal.Block(_) => ()
    }
  )

  if payloadGroups->Utils.Array.notEmpty {
    // Only reach into the store when some event selected a field beyond the
    // trio; otherwise every block is built from its item alone.
    let materialized = if anyExtra.contents {
      await store->materialize(~blockNumbers, ~masks)
    } else {
      []
    }
    payloadGroups->Array.forEachWithIndex((payloads, i) => {
      let (number, timestamp, hash) = headers->Array.getUnsafe(i)
      let block = anyExtra.contents ? materialized->Array.getUnsafe(i) : %raw(`{}`)
      block->setBlockHeader(~number, ~timestamp, ~hash)
      payloads->Array.forEach(payload => payload->Internal.setPayloadBlock(block))
    })
  }
}

// SVM: the source attaches a minimal inline block (`slot`/`time`, `hash` empty)
// to each item. Here we enrich it in place with the fields kept raw in the store
// — the real `hash` plus any selected `height`/`parentSlot`/`parentHash` — so a
// slot missing from the store (no block row) keeps the inline `slot`/`time`.
// Grouped per slot so the store is consulted once per slot; each instruction's
// own inline block is enriched in place.
let materializeSvmItems = async (store: t, ~items: array<Internal.item>) => {
  let blockNumbers = []
  let masks = []
  let blockGroups = []

  items->Array.forEach(item =>
    switch item {
    | Internal.Event(_) =>
      let eventItem = item->Internal.castUnsafeEventItem
      switch eventItem.payload->Internal.getPayloadBlock->Nullable.toOption {
      | None => () // SVM always carries an inline block; nothing to enrich.
      | Some(block) =>
        let {blockNumber} = eventItem
        let mask = eventItem.eventConfig.blockFieldMask
        let last = blockGroups->Array.length - 1
        if last >= 0 && blockNumbers->Array.getUnsafe(last) == blockNumber {
          blockGroups->Array.getUnsafe(last)->Array.push(block)
          masks->Array.setUnsafe(last, orMask(masks->Array.getUnsafe(last), mask))
        } else {
          blockNumbers->Array.push(blockNumber)
          masks->Array.push(mask)
          blockGroups->Array.push([block])
        }
      }
    | Internal.Block(_) => ()
    }
  )

  if blockGroups->Utils.Array.notEmpty {
    let materialized = await store->materialize(~blockNumbers, ~masks)
    blockGroups->Array.forEachWithIndex((blocks, i) => {
      let fields = materialized->Array.getUnsafe(i)
      blocks->Array.forEach(block => block->enrichBlock(fields))
    })
  }
}
