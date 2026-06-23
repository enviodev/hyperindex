open Vitest

// Build an `Internal.item` Event with the given store key. The payload is a bare
// object so getPayloadTransaction/setPayloadTransaction (which read/write its
// `transaction` property) behave like a real store-backed EVM payload.
let makeStoreBackedItem = (~blockNumber, ~transactionIndex): Internal.item =>
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "transactionIndex": transactionIndex,
    "payload": (Dict.make(): dict<Internal.eventTransaction>),
  }->(Utils.magic: {..} => Internal.item)

let makeInlineItem = (~blockNumber, ~transactionIndex, ~transaction): Internal.item => {
  let payload: dict<Internal.eventTransaction> = Dict.make()
  payload->Dict.set("transaction", transaction)
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "transactionIndex": transactionIndex,
    "payload": payload,
  }->(Utils.magic: {..} => Internal.item)
}

let rawTx = (item: Internal.item) =>
  (item->Internal.castUnsafeEventItem).payload->Internal.getPayloadTransaction

describe("TransactionStore field-code contract", () => {
  // The selection mask is built in ReScript from these arrays' order and decoded
  // in Rust by EvmTxField/SvmTxField ordinal, so a drift silently materialises
  // the wrong field. Pin both against the Rust ordering (the source of truth).
  it("EVM transactionFields match the Rust EvmTxField order", t => {
    t.expect(Evm.transactionFields).toEqual(Core.getAddon().evmTransactionFieldNames())
  })

  it("SVM transactionFields match the Rust SvmTxField order", t => {
    t.expect(Svm.transactionFields).toEqual(Core.getAddon().svmTransactionFieldNames())
  })
})

describe("TransactionStore.materializeItems", () => {
  Async.it("leaves payloads untouched when the mask is 0", async t => {
    let store = TransactionStore.make()
    let item = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=0)
    await store->TransactionStore.materializeItems(~items=[item], ~mask=0.)
    t.expect(rawTx(item)->Nullable.toOption).toEqual(None)
  })

  Async.it("skips inline txs, materialises store-backed items, and dedupes by adjacency", async t => {
    // Empty store ⇒ every key is a miss ⇒ materialize returns one distinct empty
    // object per group, which is enough to assert the grouping/scatter logic.
    let store = TransactionStore.make()
    let inlineTx = {"hash": "0xinline"}->(Utils.magic: {..} => Internal.eventTransaction)
    let inline = makeInlineItem(~blockNumber=1, ~transactionIndex=0, ~transaction=inlineTx)
    let a = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=1)
    let b = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=1)
    let c = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=2)

    await store->TransactionStore.materializeItems(~items=[inline, a, b, c], ~mask=2.)

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
  })
})
