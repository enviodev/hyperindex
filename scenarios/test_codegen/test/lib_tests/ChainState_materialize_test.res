open Vitest

// Build an `Internal.item` Event. `inlineTransaction`/`inlineBlock` (when
// given) put the payload in the "already inline" shape RPC/simulate/Fuel use;
// omitted, the payload is store-backed for that dimension.
// `transactionMask`/`blockMask` mirror the per-event `onEventRegistration.eventConfig`
// masks that `ChainState.groupBatchItems` reads for each dimension.
let materializeChainId = 987
let makeItem = (
  ~blockNumber,
  ~transactionIndex=0,
  ~transactionMask=0.,
  ~blockMask=0.,
  ~inlineTransaction: option<Internal.eventTransaction>=?,
  ~inlineBlock: option<Internal.eventBlock>=?,
): Internal.item => {
  let payload: dict<Internal.eventBlock> = Dict.make()
  switch inlineBlock {
  | Some(block) => payload->Dict.set("block", block)
  | None => ()
  }
  switch inlineTransaction {
  | Some(tx) =>
    payload->Dict.set("transaction", tx->(Utils.magic: Internal.eventTransaction => Internal.eventBlock))
  | None => ()
  }
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "transactionIndex": transactionIndex,
    "chain": ChainMap.Chain.makeUnsafe(~chainId=materializeChainId),
    "onEventRegistration":
      {
        "eventConfig": {"transactionFieldMask": transactionMask, "blockFieldMask": blockMask},
      }->(Utils.magic: {..} => Internal.onEventRegistration),
    "payload": payload,
  }->(Utils.magic: {..} => Internal.item)
}

let rawTx = (item: Internal.item) =>
  (item->Internal.castUnsafeEventItem).payload->Internal.getPayloadTransaction
let rawBlock = (item: Internal.item) =>
  (item->Internal.castUnsafeEventItem).payload->Internal.getPayloadBlock

// `ChainState.materializeBatchItems`/`materializePageItems` walk `items` once
// (`groupBatchItems`) to build both the transaction-store and block-store
// groups, rather than each store re-walking the batch independently. A
// transaction-dimension run (keyed by block+txIndex) and a block-dimension run
// (keyed by block alone) can diverge mid-batch — one continuing while the
// other breaks — so a single shared "last group" mistakenly reused across both
// dimensions would misgroup one of them. This pins that they stay independent.
describe("ChainState.materializePageItems: single-pass transaction/block grouping", () => {
  Async.it(
    "keeps the transaction and block adjacency runs independent within one pass",
    async t => {
      let transactionStore = TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false)
      let blockStore = BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false)

      // a, b: same (block, tx) -> share both a transaction row and a block row.
      // c: same block as a/b but a different tx -> starts a new transaction
      //    group while continuing a/b's block group.
      // d: a different block (and tx) -> its own group on both dimensions.
      let a = makeItem(~blockNumber=1, ~transactionIndex=1, ~transactionMask=2., ~blockMask=2.)
      let b = makeItem(~blockNumber=1, ~transactionIndex=1, ~transactionMask=2., ~blockMask=2.)
      let c = makeItem(~blockNumber=1, ~transactionIndex=2, ~transactionMask=2., ~blockMask=2.)
      let d = makeItem(~blockNumber=2, ~transactionIndex=1, ~transactionMask=2., ~blockMask=2.)

      await ChainState.materializePageItems(
        ~items=[a, b, c, d],
        ~transactionStore=Some(transactionStore),
        ~blockStore,
      )

      t.expect({
        "txSharedAcrossAB": rawTx(a) === rawTx(b),
        "txSeparateForDifferentIndex": rawTx(a) !== rawTx(c),
        "txSeparateForDifferentBlock": rawTx(a) !== rawTx(d),
        "blockSharedAcrossAB": rawBlock(a) === rawBlock(b),
        "blockSharedWithDifferentTxSameBlock": rawBlock(a) === rawBlock(c),
        "blockSeparateForDifferentBlock": rawBlock(a) !== rawBlock(d),
      }).toEqual({
        "txSharedAcrossAB": true,
        "txSeparateForDifferentIndex": true,
        "txSeparateForDifferentBlock": true,
        "blockSharedAcrossAB": true,
        "blockSharedWithDifferentTxSameBlock": true,
        "blockSeparateForDifferentBlock": true,
      })
    },
  )

  Async.it("materializePageItems skips the transaction side for inline sources", async t => {
    let a = makeItem(~blockNumber=1, ~transactionIndex=1, ~transactionMask=2., ~blockMask=2.)
    await ChainState.materializePageItems(
      ~items=[a],
      ~transactionStore=None,
      ~blockStore=BlockStore.make(~ecosystem=Ecosystem.Fuel, ~shouldChecksum=false),
    )
    t.expect({
      "tx": rawTx(a)->Nullable.toOption,
      // The block side always materialises from the chain store; an empty
      // store yields an empty block object.
      "blockIsSet": rawBlock(a)->Nullable.toOption->Option.isSome,
    }).toEqual({
      "tx": None,
      "blockIsSet": true,
    })
  })
})

// Migrated from BlockStore_test.res: BlockStore.materializeItems/groupByBlock
// had no real caller left (ChainState.applyBlockGroups replaced it in the
// actual runtime path), so its coverage now targets materializePageItems.
describe("ChainState.materializePageItems: block materialization", () => {
  Async.it(
    "EVM: skips inline blocks, materializes store-backed items, dedupes by block",
    async t => {
      let blockStore = BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false)
      let inlineBlock = {"number": 1}->(Utils.magic: {..} => Internal.eventBlock)
      let inline = makeItem(~blockNumber=1, ~inlineBlock)
      let mask = Evm.eventBlockFieldMask(Utils.Set.fromArray(["number", "timestamp", "hash"]))
      let a = makeItem(~blockNumber=2, ~blockMask=mask)
      let b = makeItem(~blockNumber=2, ~blockMask=mask)
      let c = makeItem(~blockNumber=3, ~blockMask=mask)

      // The store is empty, so of the trio only `number` — resolved from the
      // requested key rather than a stored block — comes back.
      await ChainState.materializePageItems(
        ~items=[inline, a, b, c],
        ~transactionStore=None,
        ~blockStore,
      )

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

  Async.it(
    "SVM: skips inline blocks, materializes store-backed items, dedupes by slot",
    async t => {
      let blockStore = BlockStore.make(~ecosystem=Ecosystem.Svm, ~shouldChecksum=false)
      let inlineBlock = {"slot": 1}->(Utils.magic: {..} => Internal.eventBlock)
      let inline = makeItem(~blockNumber=1, ~inlineBlock)
      let mask = Svm.eventBlockFieldMask(Utils.Set.fromArray(["slot", "time", "hash"]))
      let a = makeItem(~blockNumber=5, ~blockMask=mask)
      let b = makeItem(~blockNumber=5, ~blockMask=mask)
      let c = makeItem(~blockNumber=6, ~blockMask=mask)

      // The store is empty, so of the trio only `slot` — resolved from the
      // requested key rather than a stored block — comes back.
      await ChainState.materializePageItems(
        ~items=[inline, a, b, c],
        ~transactionStore=None,
        ~blockStore,
      )

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

// Migrated from TransactionStore_test.res: TransactionStore.materializeItems
// had no real caller left (ChainState.applyTransactionGroups replaced it in
// the actual runtime path), so its coverage now targets materializePageItems.
describe("ChainState.materializePageItems: transaction materialization", () => {
  Async.it("stamps an empty transaction object when the mask is 0", async t => {
    let transactionStore = TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false)
    let item = makeItem(~blockNumber=1, ~transactionIndex=0, ~transactionMask=0.)
    await ChainState.materializePageItems(
      ~items=[item],
      ~transactionStore=Some(transactionStore),
      ~blockStore=BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
    )
    // Store-backed items always get a transaction object (matching the inline
    // sources) — an empty object rather than `undefined` — even with no fields.
    t.expect(rawTx(item)->Nullable.toOption).toEqual(Some(%raw(`{}`)))
  })

  Async.it(
    "skips inline transactions, materializes store-backed items, dedupes by adjacency",
    async t => {
      // Empty store ⇒ every key is a miss ⇒ materialize returns one distinct empty
      // object per group, which is enough to assert the grouping/scatter logic.
      let transactionStore = TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false)
      let inlineTx = {"hash": "0xinline"}->(Utils.magic: {..} => Internal.eventTransaction)
      let inline = makeItem(~blockNumber=1, ~transactionIndex=0, ~inlineTransaction=inlineTx)
      let a = makeItem(~blockNumber=1, ~transactionIndex=1, ~transactionMask=2.)
      let b = makeItem(~blockNumber=1, ~transactionIndex=1, ~transactionMask=2.)
      let c = makeItem(~blockNumber=1, ~transactionIndex=2, ~transactionMask=2.)

      await ChainState.materializePageItems(
        ~items=[inline, a, b, c],
        ~transactionStore=Some(transactionStore),
        ~blockStore=BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
      )

      t.expect({
        "inlineUntouched": rawTx(inline) === inlineTx->Nullable.make,
        "storeBackedMaterialised": rawTx(a)->Nullable.toOption->Option.isSome,
        "adjacentSameKeyShared": rawTx(a) === rawTx(b),
        "differentKeySeparate": rawTx(a) !== rawTx(c),
      }).toEqual({
        "inlineUntouched": true,
        "storeBackedMaterialised": true,
        "adjacentSameKeyShared": true,
        "differentKeySeparate": true,
      })
    },
  )

  Async.it("groups adjacent events on one transaction even when their masks differ", async t => {
    // Two events on the same (block, tx) but with different per-event masks must
    // still share one row (their masks OR'd together), while an event on another
    // tx stays separate. Exercises the orMask union path (the empty store yields
    // one distinct empty object per row).
    let transactionStore = TransactionStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false)
    let a = makeItem(~blockNumber=1, ~transactionIndex=1, ~transactionMask=2.)
    let b = makeItem(~blockNumber=1, ~transactionIndex=1, ~transactionMask=4.)
    let c = makeItem(~blockNumber=1, ~transactionIndex=2, ~transactionMask=0.)

    await ChainState.materializePageItems(
      ~items=[a, b, c],
      ~transactionStore=Some(transactionStore),
      ~blockStore=BlockStore.make(~ecosystem=Ecosystem.Evm, ~shouldChecksum=false),
    )

    t.expect({
      "differentMasksSameTxShared": rawTx(a) === rawTx(b),
      "zeroMaskStillStamped": rawTx(c)->Nullable.toOption->Option.isSome,
      "differentTxSeparate": rawTx(a) !== rawTx(c),
    }).toEqual({
      "differentMasksSameTxShared": true,
      "zeroMaskStillStamped": true,
      "differentTxSeparate": true,
    })
  })
})
