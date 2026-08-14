open Vitest

// `FieldMask.orMask` is `(a | b) >>> 0`, so a field whose code is 32 or higher
// is silently dropped the moment two selections merge or two items group — the
// mask itself stays exact (it sums `2**code` in f64), which is what makes the
// loss quiet. EVM transactions already sit exactly on the ceiling, so this is
// the test that has to fail before a 33rd field lands.
describe("field-code mask ceiling", () => {
  it("no ecosystem exceeds the 32 field codes a mask can hold", t => {
    t.expect({
      // Pinned because it sits exactly on the ceiling — the next EVM
      // transaction field is the one that breaks `orMask`.
      "evmTransaction": Evm.transactionFields->Array.length,
      "overCeiling": [
        Evm.transactionFields,
        Evm.blockFields,
        Svm.transactionFields,
        Svm.blockFields,
        Fuel.blockFields,
      ]->Array.filter(fields => fields->Array.length > 32),
    }).toEqual({
      "evmTransaction": 32,
      // Widen `orMask` (BigInt, or a pair of floats) before adding the 33rd.
      "overCeiling": [],
    })
  })

  it("orMask drops a field code at the ceiling", t =>
    // Pins the failure mode the count guards against, so the reason the ceiling
    // is 32 stays legible.
    t.expect((
      FieldMask.orMask(FieldMask.pow2(31), 1.),
      FieldMask.orMask(FieldMask.pow2(32), 1.),
    )).toEqual((2147483649., 1.))
  )
})

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
