open Vitest

// Build an `Internal.item` Event for a store-backed block. The payload is a bare
// object so getPayloadBlock/setPayloadBlock (which read/write its `block`
// property) behave like a real store-backed EVM payload. `mask` mirrors the
// per-event `eventConfig.blockFieldMask` that materializeItems reads to decide
// whether to consult the store for fields beyond number/timestamp/hash.
let makeStoreBackedItem = (~blockNumber, ~timestamp, ~blockHash, ~mask=0.): Internal.item =>
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "timestamp": timestamp,
    "blockHash": blockHash,
    "transactionIndex": 0,
    "eventConfig": {"blockFieldMask": mask},
    "payload": (Dict.make(): dict<Internal.eventBlock>),
  }->(Utils.magic: {..} => Internal.item)

let makeInlineItem = (~blockNumber, ~timestamp, ~blockHash, ~block): Internal.item => {
  let payload: dict<Internal.eventBlock> = Dict.make()
  payload->Dict.set("block", block)
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "timestamp": timestamp,
    "blockHash": blockHash,
    "transactionIndex": 0,
    "payload": payload,
  }->(Utils.magic: {..} => Internal.item)
}

let rawBlock = (item: Internal.item) =>
  (item->Internal.castUnsafeEventItem).payload->Internal.getPayloadBlock

describe("BlockStore field-code contract", () => {
  // The selection mask is built in ReScript from this array's order and decoded
  // in Rust by EvmBlockField ordinal, so a drift silently materialises the wrong
  // field. Pin both against the Rust ordering (the source of truth).
  it("EVM blockFields match the Rust EvmBlockField order", t => {
    t.expect(Evm.blockFields).toEqual(Core.getAddon().evmBlockFieldNames())
  })
})

describe("BlockStore materializeItems", () => {
  Async.it(
    "skips inline blocks, stamps the trio on store-backed items, and dedupes by block",
    async t => {
      let store = BlockStore.make()
      let inlineBlock = {"number": 1}->(Utils.magic: {..} => Internal.eventBlock)
      let inline = makeInlineItem(~blockNumber=1, ~timestamp=11, ~blockHash="0x1", ~block=inlineBlock)
      // No event selects a field beyond the trio, so the block is built from the
      // item alone (number/timestamp/hash), with no store lookup.
      let a = makeStoreBackedItem(~blockNumber=2, ~timestamp=22, ~blockHash="0x2")
      let b = makeStoreBackedItem(~blockNumber=2, ~timestamp=22, ~blockHash="0x2")
      let c = makeStoreBackedItem(~blockNumber=3, ~timestamp=33, ~blockHash="0x3")

      await store->BlockStore.materializeItems(~items=[inline, a, b, c])

      t.expect({
        "inlineUntouched": rawBlock(inline) === inlineBlock->Nullable.make,
        "storeBackedTrioStamped": rawBlock(a),
        "adjacentSameBlockShared": rawBlock(a) === rawBlock(b),
        "differentBlockSeparate": rawBlock(a) !== rawBlock(c),
      }).toEqual({
        "inlineUntouched": true,
        "storeBackedTrioStamped": {"number": 2, "timestamp": 22, "hash": "0x2"}
        ->(Utils.magic: {..} => Internal.eventBlock)
        ->Nullable.make,
        "adjacentSameBlockShared": true,
        "differentBlockSeparate": true,
      })
    },
  )
})
