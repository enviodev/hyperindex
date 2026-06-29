open Vitest

// Build an `Internal.item` Event with the given store key. The payload is a bare
// object so getPayloadTransaction/setPayloadTransaction (which read/write its
// `transaction` property) behave like a real store-backed EVM payload.
// `mask` mirrors the per-event `eventConfig.transactionFieldMask` that
// materializeItems reads to decide which fields to materialise for the item.
let makeStoreBackedItem = (~blockNumber, ~transactionIndex, ~mask=2.): Internal.item =>
  {
    "kind": 0,
    "blockNumber": blockNumber,
    "transactionIndex": transactionIndex,
    "eventConfig": {"transactionFieldMask": mask},
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

  // `Internal` holds a third copy of each field list (the schema enums); pin it
  // to the same Rust ordering so all three stay aligned.
  it("EVM Internal.allEvmTransactionFields match the Rust EvmTxField order", t => {
    t.expect(
      Internal.allEvmTransactionFields->(
        Utils.magic: array<Internal.evmTransactionField> => array<string>
      ),
    ).toEqual(Core.getAddon().evmTransactionFieldNames())
  })

  it("SVM Internal.allSvmTransactionFields match the Rust SvmTxField order", t => {
    t.expect(
      Internal.allSvmTransactionFields->(
        Utils.magic: array<Internal.svmTransactionField> => array<string>
      ),
    ).toEqual(Core.getAddon().svmTransactionFieldNames())
  })

  it("fieldCodes maps each field name to its bit index", t => {
    t.expect(TransactionStore.fieldCodes(["transactionIndex", "hash", "from"])).toEqual(
      Dict.fromArray([("transactionIndex", 0), ("hash", 1), ("from", 2)]),
    )
  })

  it("orMask combines field masks as unsigned 32-bit values", t => {
    // The highest EVM field code is 31, so the highest mask bit is 2^31. A plain
    // JS `|` renders that bit negative; orMask's `>>> 0` recovers the unsigned
    // value. These pin both the disjoint/overlapping cases and the bit-31 edge.
    t.expect({
      "disjoint": TransactionStore.orMask(1., 2.),
      "overlapping": TransactionStore.orMask(3., 6.),
      "bit31WithLowBit": TransactionStore.orMask(2147483648., 1.),
      "allBits": TransactionStore.orMask(4294967295., 2147483648.),
    }).toEqual({
      "disjoint": 3.,
      "overlapping": 7.,
      "bit31WithLowBit": 2147483649.,
      "allBits": 4294967295.,
    })
  })
})

describe("TransactionStore.materializeItems", () => {
  Async.it("stamps an empty transaction object when the mask is 0", async t => {
    let store = TransactionStore.make()
    let item = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=0, ~mask=0.)
    await store->TransactionStore.materializeItems(~items=[item])
    // Store-backed items always get a transaction object (matching the inline
    // sources) — an empty object rather than `undefined` — even with no fields.
    t.expect(rawTx(item)->Nullable.toOption).toEqual(Some(%raw(`{}`)))
  })

  Async.it(
    "skips inline txs, materialises store-backed items, and dedupes by adjacency",
    async t => {
      // Empty store ⇒ every key is a miss ⇒ materialize returns one distinct empty
      // object per group, which is enough to assert the grouping/scatter logic.
      let store = TransactionStore.make()
      let inlineTx = {"hash": "0xinline"}->(Utils.magic: {..} => Internal.eventTransaction)
      let inline = makeInlineItem(~blockNumber=1, ~transactionIndex=0, ~transaction=inlineTx)
      let a = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=1)
      let b = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=1)
      let c = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=2)

      await store->TransactionStore.materializeItems(~items=[inline, a, b, c])

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
    // tx stays separate. Exercises the orMask union path through materializeItems
    // (the empty store yields one distinct empty object per row).
    let store = TransactionStore.make()
    let a = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=1, ~mask=2.)
    let b = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=1, ~mask=4.)
    let c = makeStoreBackedItem(~blockNumber=1, ~transactionIndex=2, ~mask=0.)

    await store->TransactionStore.materializeItems(~items=[a, b, c])

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
