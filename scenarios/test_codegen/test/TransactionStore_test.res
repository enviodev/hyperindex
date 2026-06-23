open Vitest

// The order of these field-name arrays is the cross-language contract: index i
// must match the Rust `EvmTxField`/`SvmTxField` ordinal i (and its `name()`),
// which is the bit position in the materialisation mask. The Rust side pins its
// own order in a unit test; this pins the ReScript order so the two can't
// silently drift (a reorder/rename here would otherwise materialise the wrong
// column at runtime with nothing failing).
describe("TransactionStore field-code contract", () => {
  it("Evm.transactionFields preserve the shared ordinal order", t => {
    t.expect(Evm.transactionFields).toEqual([
      "transactionIndex",
      "hash",
      "from",
      "to",
      "gas",
      "gasPrice",
      "maxPriorityFeePerGas",
      "maxFeePerGas",
      "cumulativeGasUsed",
      "effectiveGasPrice",
      "gasUsed",
      "input",
      "nonce",
      "value",
      "v",
      "r",
      "s",
      "contractAddress",
      "logsBloom",
      "root",
      "status",
      "yParity",
      "chainId",
      "maxFeePerBlobGas",
      "blobVersionedHashes",
      "type",
      "l1Fee",
      "l1GasPrice",
      "l1GasUsed",
      "l1FeeScalar",
      "gasUsedForL1",
      "accessList",
      "authorizationList",
    ])
  })

  it("Svm.transactionFields preserve the shared ordinal order", t => {
    t.expect(Svm.transactionFields).toEqual([
      "transactionIndex",
      "signatures",
      "feePayer",
      "success",
      "err",
      "fee",
      "computeUnitsConsumed",
      "accountKeys",
      "recentBlockhash",
      "version",
      "tokenBalances",
    ])
  })

  it("fieldCodes maps each field name to its bit index", t => {
    t.expect(TransactionStore.fieldCodes(["transactionIndex", "hash", "from"])).toEqual(
      Dict.fromArray([("transactionIndex", 0), ("hash", 1), ("from", 2)]),
    )
  })
})
