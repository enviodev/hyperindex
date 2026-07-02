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

// SVM items carry the always-available trio (`slot`/`time`/`hash`) inline; when a
// field beyond the trio is selected, materializeSvmItems enriches the block in
// place from the store.
let makeSvmItem = (~slot, ~time, ~hash, ~mask): Internal.item => {
  let block = {"slot": slot, "time": time, "hash": hash}->(Utils.magic: {..} => Internal.eventBlock)
  let payload: dict<Internal.eventBlock> = Dict.make()
  payload->Dict.set("block", block)
  {
    "kind": 0,
    "blockNumber": slot,
    "timestamp": time,
    "blockHash": "",
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

  // `BlockStore.hasExtraFields` clears the always-stamped trio with `& ~7`, which
  // assumes number/timestamp/hash are field codes 0/1/2. Pin that here so a
  // reorder of `blockFields` can't silently break the store short-circuit.
  it("EVM always-stamped trio occupies field codes 0/1/2", t => {
    t.expect(Evm.blockFields->Array.slice(~start=0, ~end=3)).toEqual(["number", "timestamp", "hash"])
  })

  it("SVM blockFields match the Rust SvmBlockField order", t => {
    t.expect(Svm.blockFields).toEqual(Core.getAddon().svmBlockFieldNames())
  })

  // SVM shares `hasExtraFields`' `& ~7`, so its always-inline trio must occupy
  // field codes 0/1/2 too. Pin it so a reorder can't silently route slot/time/
  // hash through the store (which the SVM source never populates for them).
  it("SVM always-inline trio occupies field codes 0/1/2", t => {
    t.expect(Svm.blockFields->Array.slice(~start=0, ~end=3)).toEqual(["slot", "time", "hash"])
  })
})

describe("BlockStore materializeItems", () => {
  Async.it(
    "skips inline blocks, stamps the trio on store-backed items, and dedupes by block",
    async t => {
      let store = BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false)
      let inlineBlock = {"number": 1}->(Utils.magic: {..} => Internal.eventBlock)
      let inline = makeInlineItem(~blockNumber=1, ~timestamp=11, ~blockHash="0x1", ~block=inlineBlock)
      // No event selects a field beyond the trio, so the block is built from the
      // item alone (number/timestamp/hash), with no store lookup.
      let a = makeStoreBackedItem(~blockNumber=2, ~timestamp=22, ~blockHash="0x2")
      let b = makeStoreBackedItem(~blockNumber=2, ~timestamp=22, ~blockHash="0x2")
      let c = makeStoreBackedItem(~blockNumber=3, ~timestamp=33, ~blockHash="0x3")

      await store->BlockStore.materializeEvmItems(~items=[inline, a, b, c])

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

  Async.it("enriches each slot's inline block in place and dedupes by slot", async t => {
    let store = BlockStore.make(~ecosystem=Ecosystem.Svm, ~shouldChecksum=false)
    let mask = Svm.eventBlockFieldMask(Utils.Set.fromArray(Svm.blockFields))
    let a = makeSvmItem(~slot=5, ~time=50, ~hash="0x5", ~mask)
    let b = makeSvmItem(~slot=5, ~time=50, ~hash="0x5", ~mask)
    let c = makeSvmItem(~slot=6, ~time=60, ~hash="0x6", ~mask)

    // The store is empty here, so the extra fields don't materialise; each item's
    // own inline block is enriched in place, keeping its slot/time/hash. This
    // exercises the enrich/dedup path — field decoding itself is covered by the
    // Rust unit tests.
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

  // Regression: selecting only trio fields (`time`/`hash`) must leave the inline
  // block intact. The SVM source never populates the store for the trio, so a
  // gate on `mask != 0.` would consult the empty store and drop time/hash;
  // gating on `hasExtraFields` keeps them.
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
