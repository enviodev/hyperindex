open Vitest

// Build an `Internal.item` Event for a store-backed block. The payload is a bare
// object so getPayloadBlock/setPayloadBlock (which read/write its `block`
// property) behave like a real store-backed EVM payload. `mask` mirrors the
// per-event `eventConfig.blockFieldMask` — for EVM it always carries the
// number/timestamp/hash bits, added to the selection at config build.
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

// SVM items carry the always-available trio (`slot`/`time`/`hash`) inline; the
// selected fields are enriched onto the block in place from the store.
let makeSvmItem = (~slot, ~time, ~hash, ~mask): Internal.item => {
  let block = {"slot": slot, "time": time, "hash": hash}->(Utils.magic: {..} => Internal.eventBlock)
  let payload: dict<Internal.eventBlock> = Dict.make()
  payload->Dict.set("block", block)
  {
    "kind": 0,
    "blockNumber": slot,
    "transactionIndex": 0,
    "eventConfig": {"blockFieldMask": mask},
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
    "skips inline blocks, sets a store block on store-backed items, and dedupes by block",
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
      await store->BlockStore.materializeEvmItems(~items=[inline, a, b, c])

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

  Async.it("enriches each slot's inline block in place and dedupes by slot", async t => {
    let store = BlockStore.make(~ecosystem=Ecosystem.Svm, ~shouldChecksum=false)
    let mask = Svm.eventBlockFieldMask(Utils.Set.fromArray(Svm.blockFields))
    let a = makeSvmItem(~slot=5, ~time=50, ~hash="0x5", ~mask)
    let b = makeSvmItem(~slot=5, ~time=50, ~hash="0x5", ~mask)
    let c = makeSvmItem(~slot=6, ~time=60, ~hash="0x6", ~mask)

    // The store is empty here, so the selected fields don't materialise; each
    // item's own inline block is enriched in place, keeping its slot/time/hash.
    // This exercises the enrich/dedup path — field decoding itself is covered by
    // the Rust unit tests.
    await store->BlockStore.materializeSvmItems(~items=[a, b, c])

    t.expect({
      "aBlock": rawBlock(a),
      "bBlock": rawBlock(b),
      "cBlock": rawBlock(c),
    }).toEqual({
      "aBlock": {"slot": 5, "time": 50, "hash": "0x5"}
      ->(Utils.magic: {..} => Internal.eventBlock)
      ->Nullable.make,
      "bBlock": {"slot": 5, "time": 50, "hash": "0x5"}
      ->(Utils.magic: {..} => Internal.eventBlock)
      ->Nullable.make,
      "cBlock": {"slot": 6, "time": 60, "hash": "0x6"}
      ->(Utils.magic: {..} => Internal.eventBlock)
      ->Nullable.make,
    })
  })

  // Selecting only inline-stamped fields (`time`/`hash`) must leave the inline
  // block intact: the SVM source doesn't populate the store for them, so the
  // materialise call yields empty bags and the enrich is a no-op.
  Async.it("keeps the inline trio when only time/hash are selected", async t => {
    let store = BlockStore.make(~ecosystem=Ecosystem.Svm, ~shouldChecksum=false)
    let mask = Svm.eventBlockFieldMask(Utils.Set.fromArray(["time", "hash"]))
    let item = makeSvmItem(~slot=7, ~time=70, ~hash="0x7", ~mask)

    await store->BlockStore.materializeSvmItems(~items=[item])

    t.expect(rawBlock(item)).toEqual(
      {"slot": 7, "time": 70, "hash": "0x7"}
      ->(Utils.magic: {..} => Internal.eventBlock)
      ->Nullable.make,
    )
  })
})
