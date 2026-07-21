open Vitest

describe("TransactionStore field-code contract", () => {
  // The selection mask is built in ReScript from these arrays' order and decoded
  // in Rust by EvmTxField/SvmTxField ordinal, so a drift silently materialises
  // the wrong field. `Evm.transactionFields`/`Svm.transactionFields` derive from
  // these typed lists, so pinning them to the Rust ordering covers both.
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
