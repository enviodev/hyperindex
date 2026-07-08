open Vitest

// Build an `Internal.item` Event with neither `transaction` nor `block` inline
// on the payload, so both are store-backed. `transactionMask`/`blockMask`
// mirror the per-event `onEventRegistration.eventConfig` masks that
// `ChainState.groupBatchItems` reads for each dimension.
let makeItem = (~blockNumber, ~transactionIndex, ~transactionMask=2., ~blockMask=2.): Internal.item =>
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "transactionIndex": transactionIndex,
    "onEventRegistration": {
      "eventConfig": {"transactionFieldMask": transactionMask, "blockFieldMask": blockMask},
    },
    "payload": (Dict.make(): dict<Internal.eventBlock>),
  }->(Utils.magic: {..} => Internal.item)

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
      let a = makeItem(~blockNumber=1, ~transactionIndex=1)
      let b = makeItem(~blockNumber=1, ~transactionIndex=1)
      let c = makeItem(~blockNumber=1, ~transactionIndex=2)
      let d = makeItem(~blockNumber=2, ~transactionIndex=1)

      await ChainState.materializePageItems(
        ~items=[a, b, c, d],
        ~transactionStore=Some(transactionStore),
        ~blockStore=Some(blockStore),
        ~ecosystem=Ecosystem.Evm,
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

  Async.it("materializePageItems is a no-op for None pages (RPC/Fuel/Simulate)", async t => {
    let a = makeItem(~blockNumber=1, ~transactionIndex=1)
    await ChainState.materializePageItems(
      ~items=[a],
      ~transactionStore=None,
      ~blockStore=None,
      ~ecosystem=Ecosystem.Fuel,
    )
    t.expect({
      "tx": rawTx(a)->Nullable.toOption,
      "block": rawBlock(a)->Nullable.toOption,
    }).toEqual({
      "tx": None,
      "block": None,
    })
  })
})
