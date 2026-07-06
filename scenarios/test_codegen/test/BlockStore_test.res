open Vitest

// Build an `Internal.item` Event for a store-backed block. The payload is a bare
// object so getPayloadBlock/setPayloadBlock (which read/write its `block`
// property) behave like a real store-backed payload. `mask` mirrors the
// per-event `eventConfig.blockFieldMask` — every ecosystem's mask always
// carries its always-included trio, added to the selection at config build.
let makeStoreBackedItem = (~blockNumber, ~mask): Internal.item =>
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "transactionIndex": 0,
    "eventConfig": {"blockFieldMask": mask},
    "payload": (Dict.make(): dict<Internal.eventBlock>),
  }->(Utils.magic: {..} => Internal.item)

let makeInlineItem = (~blockNumber, ~block): Internal.item => {
  let payload: dict<Internal.eventBlock> = Dict.make()
  payload->Dict.set("block", block)
  {
    "kind": 0,
    "blockNumber": blockNumber,
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

  it("SVM blockFields match the Rust SvmBlockField order", t => {
    t.expect(Svm.blockFields).toEqual(Core.getAddon().svmBlockFieldNames())
  })
})

describe("BlockStore materializeItems", () => {
  Async.it(
    "EVM: skips inline blocks, sets a store block on store-backed items, and dedupes by block",
    async t => {
      let store = BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false)
      let inlineBlock = {"number": 1}->(Utils.magic: {..} => Internal.eventBlock)
      let inline = makeInlineItem(~blockNumber=1, ~block=inlineBlock)
      let mask = Evm.eventBlockFieldMask(Utils.Set.fromArray(["number", "timestamp", "hash"]))
      let a = makeStoreBackedItem(~blockNumber=2, ~mask)
      let b = makeStoreBackedItem(~blockNumber=2, ~mask)
      let c = makeStoreBackedItem(~blockNumber=3, ~mask)

      // The store is empty (only Rust sources feed it), so of the trio only
      // `number` — resolved from the requested key rather than a stored block —
      // comes back. This exercises the group/dedup/assign path; full field
      // decoding is covered by the Rust unit tests.
      await store->BlockStore.materializeItems(~items=[inline, a, b, c])

      t.expect({
        "inlineUntouched": rawBlock(inline) === inlineBlock->Nullable.make,
        "storeBackedBlockSet": rawBlock(a),
        "adjacentSameBlockShared": rawBlock(a) === rawBlock(b),
        "differentBlockSeparate": rawBlock(a) !== rawBlock(c),
      }).toEqual({
        "inlineUntouched": true,
        "storeBackedBlockSet": {"number": 2}
        ->(Utils.magic: {..} => Internal.eventBlock)
        ->Nullable.make,
        "adjacentSameBlockShared": true,
        "differentBlockSeparate": true,
      })
    },
  )

  // Same mechanism as EVM (`materializeItems` doesn't branch by ecosystem):
  // SVM's always-included slot/time/hash trio (mask bits 0-2) takes the exact
  // same group/dedup/assign path as EVM's number/timestamp/hash.
  Async.it(
    "SVM: skips inline blocks, sets a store block on store-backed items, and dedupes by slot",
    async t => {
      let store = BlockStore.make(~ecosystem=Ecosystem.Svm, ~shouldChecksum=false)
      let inlineBlock = {"slot": 1}->(Utils.magic: {..} => Internal.eventBlock)
      let inline = makeInlineItem(~blockNumber=1, ~block=inlineBlock)
      let mask = Svm.eventBlockFieldMask(Utils.Set.fromArray(["slot", "time", "hash"]))
      let a = makeStoreBackedItem(~blockNumber=5, ~mask)
      let b = makeStoreBackedItem(~blockNumber=5, ~mask)
      let c = makeStoreBackedItem(~blockNumber=6, ~mask)

      // The store is empty, so of the trio only `slot` — resolved from the
      // requested key rather than a stored block — comes back.
      await store->BlockStore.materializeItems(~items=[inline, a, b, c])

      t.expect({
        "inlineUntouched": rawBlock(inline) === inlineBlock->Nullable.make,
        "storeBackedBlockSet": rawBlock(a),
        "adjacentSameSlotShared": rawBlock(a) === rawBlock(b),
        "differentSlotSeparate": rawBlock(a) !== rawBlock(c),
      }).toEqual({
        "inlineUntouched": true,
        "storeBackedBlockSet": {"slot": 5}
        ->(Utils.magic: {..} => Internal.eventBlock)
        ->Nullable.make,
        "adjacentSameSlotShared": true,
        "differentSlotSeparate": true,
      })
    },
  )
})
