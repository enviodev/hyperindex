open Vitest

// A build joins each item to the transaction and block it reads from the
// chain's buffer. Items enter as simulate items: a payload without a
// `transaction` or `block` of its own reads them from the buffer, one with them
// keeps its own.
let chainId = 987->ChainId.fromInt

let registration = (~index, ~transactionMask=0., ~blockMask=0.) =>
  {
    "index": index,
    "fieldSelection": {"transactionMask": transactionMask, "blockMask": blockMask},
  }->(Utils.magic: {..} => Internal.onEventRegistration)

let makeItem = (
  ~registration: Internal.onEventRegistration,
  ~blockNumber,
  ~logIndex,
  ~transactionIndex=0,
  ~inlineTransaction: option<Internal.eventTransaction>=?,
  ~inlineBlock: option<Internal.eventBlock>=?,
): Internal.item => {
  let payload: dict<unknown> = Dict.make()
  switch inlineBlock {
  | Some(block) => payload->Dict.set("block", block->(Utils.magic: Internal.eventBlock => unknown))
  | None => ()
  }
  switch inlineTransaction {
  | Some(transaction) =>
    payload->Dict.set(
      "transaction",
      transaction->(Utils.magic: Internal.eventTransaction => unknown),
    )
  | None => ()
  }
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "logIndex": logIndex,
    "transactionIndex": transactionIndex,
    "chainId": chainId,
    "onEventRegistration": registration,
    "payload": payload,
  }->(Utils.magic: {..} => Internal.item)
}

let buildJoined = async (items, ~registrations, ~ecosystem=Ecosystem.Evm) =>
  await TestChainBuffer.pageOf(items, ~ecosystem)->TestChainBuffer.buildAll(
    ~buffer=TestChainBuffer.decodedBuffer(~onEventRegistrations=registrations, ~ecosystem),
    ~context={chainId, onEventRegistrations: registrations, onBlockRegistrations: []},
  )

let rawTx = (item: Internal.item) =>
  (item->Internal.castUnsafeEventItem).payload->Internal.getPayloadTransaction
let rawBlock = (item: Internal.item) =>
  (item->Internal.castUnsafeEventItem).payload->Internal.getPayloadBlock

describe("A build's joins", () => {
  // A transaction run (block and transaction index) and a block run (block
  // alone) can break at different items, so each is grouped on its own.
  Async.it(
    "shares one transaction and one block object per run, each grouped on its own",
    async t => {
      let selecting = registration(~index=0, ~transactionMask=2., ~blockMask=2.)
      let items =
        [(1, 1), (1, 1), (1, 2), (2, 1)]->Array.mapWithIndex(
          ((blockNumber, transactionIndex), logIndex) =>
            makeItem(~registration=selecting, ~blockNumber, ~logIndex, ~transactionIndex),
        )
      let taken = await items->buildJoined(~registrations=[selecting])
      let at = Array.getUnsafe(taken, ...)
      t.expect({
        "txSharedAcrossSameTransaction": rawTx(at(0)) === rawTx(at(1)),
        "txSeparateForDifferentIndex": rawTx(at(0)) !== rawTx(at(2)),
        "txSeparateForDifferentBlock": rawTx(at(0)) !== rawTx(at(3)),
        "blockSharedAcrossSameBlock": rawBlock(at(0)) === rawBlock(at(2)),
        "blockSeparateForDifferentBlock": rawBlock(at(0)) !== rawBlock(at(3)),
      }).toEqual({
        "txSharedAcrossSameTransaction": true,
        "txSeparateForDifferentIndex": true,
        "txSeparateForDifferentBlock": true,
        "blockSharedAcrossSameBlock": true,
        "blockSeparateForDifferentBlock": true,
      })
    },
  )

  Async.it("leaves an item's own transaction and block alone", async t => {
    let selecting = registration(~index=0, ~transactionMask=2., ~blockMask=2.)
    let taken = await [
      makeItem(
        ~registration=selecting,
        ~blockNumber=1,
        ~logIndex=0,
        ~inlineTransaction=%raw(`{"id": "0xfuel"}`),
        ~inlineBlock=%raw(`{"height": 1}`),
      ),
    ]->buildJoined(~registrations=[selecting])
    t.expect((rawTx(taken->Array.getUnsafe(0)), rawBlock(taken->Array.getUnsafe(0)))).toEqual((
      %raw(`{"id": "0xfuel"}`),
      %raw(`{"height": 1}`),
    ))
  })

  Async.it(
    "reads the selected block fields, and a block's number even when it is not stored",
    async t => {
      let mask = Evm.eventBlockFieldMask(Utils.Set.fromArray(["number", "timestamp", "hash"]))
      let selecting = registration(~index=0, ~blockMask=mask)
      let taken = await [2, 2, 3]
      ->Array.mapWithIndex(
        (blockNumber, logIndex) => makeItem(~registration=selecting, ~blockNumber, ~logIndex),
      )
      ->buildJoined(~registrations=[selecting])
      t.expect(
        taken->Array.map(
          item =>
            rawBlock(item)
            ->Nullable.toOption
            ->Option.map(block => block->(Utils.magic: Internal.eventBlock => {"number": int})),
        ),
      ).toEqual([Some({"number": 2}), Some({"number": 2}), Some({"number": 3})])
    },
  )

  Async.it("reads an SVM block by its slot", async t => {
    let mask = Svm.eventBlockFieldMask(Utils.Set.fromArray(["slot", "time", "hash"]))
    let selecting = registration(~index=0, ~blockMask=mask)
    let taken = await [makeItem(~registration=selecting, ~blockNumber=5, ~logIndex=0)]->buildJoined(
      ~registrations=[selecting],
      ~ecosystem=Ecosystem.Svm,
    )
    t.expect(
      rawBlock(taken->Array.getUnsafe(0))
      ->Nullable.toOption
      ->Option.map(block => block->(Utils.magic: Internal.eventBlock => {"slot": int})),
    ).toEqual(Some({"slot": 5}))
  })

  // Buffer-backed items always get a transaction object, matching the sources
  // that carry it inline, even when no field of it is selected.
  Async.it("gives each item an empty transaction of its own when none is selected", async t => {
    let plain = registration(~index=0)
    let taken = await [1, 1]
    ->Array.mapWithIndex((_, logIndex) => makeItem(~registration=plain, ~blockNumber=1, ~logIndex))
    ->buildJoined(~registrations=[plain])
    let at = Array.getUnsafe(taken, ...)
    t.expect((rawTx(at(0))->Nullable.toOption, rawTx(at(0)) === rawTx(at(1)))).toEqual((
      Some(%raw(`{}`)),
      false,
    ))
  })

  // A field the buffer has no value for is left off the object, rather than
  // set to `undefined`, as on the inline sources.
  Async.it("leaves a field the buffer has no value for off the object", async t => {
    let mask = Evm.eventTransactionFieldMask(Utils.Set.fromArray(["hash"]))
    let selecting = registration(~index=0, ~transactionMask=mask)
    let taken = await [makeItem(~registration=selecting, ~blockNumber=1, ~logIndex=0)]->buildJoined(
      ~registrations=[selecting],
    )
    t.expect(
      rawTx(taken->Array.getUnsafe(0))
      ->Nullable.toOption
      ->Option.map(
        transaction =>
          transaction->(Utils.magic: Internal.eventTransaction => dict<unknown>)->Dict.keysToArray,
      ),
    ).toEqual(Some([]))
  })

  Async.it("shares a transaction between items selecting different fields of it", async t => {
    let first = registration(~index=0, ~transactionMask=2.)
    let second = registration(~index=1, ~transactionMask=4.)
    let none = registration(~index=2)
    let taken = await [
      makeItem(~registration=first, ~blockNumber=1, ~logIndex=0, ~transactionIndex=1),
      makeItem(~registration=second, ~blockNumber=1, ~logIndex=1, ~transactionIndex=1),
      makeItem(~registration=none, ~blockNumber=1, ~logIndex=2, ~transactionIndex=2),
    ]->buildJoined(~registrations=[first, second, none])
    let at = Array.getUnsafe(taken, ...)
    t.expect({
      "differentMasksSameTxShared": rawTx(at(0)) === rawTx(at(1)),
      "unselectingItemStillGetsOne": rawTx(at(2))->Nullable.toOption->Option.isSome,
      "differentTxSeparate": rawTx(at(0)) !== rawTx(at(2)),
    }).toEqual({
      "differentMasksSameTxShared": true,
      "unselectingItemStillGetsOne": true,
      "differentTxSeparate": true,
    })
  })
})
