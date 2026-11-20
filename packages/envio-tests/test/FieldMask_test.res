open Vitest

// A mask is a float summing `2**code`, exact while every code is below 53.
// `orMask` must keep every one of those bits when two selections merge.
describe("field-code mask ceiling", () => {
  it("no ecosystem exceeds the 53 field codes a mask can hold", t => {
    t.expect({
      "evmTransaction": Evm.transactionFields->Array.length,
      "overCeiling": [
        Evm.transactionFields,
        Evm.blockFields,
        Svm.transactionFields,
        Svm.blockFields,
        Fuel.blockFields,
      ]->Array.filter(fields => fields->Array.length > 53),
    }).toEqual({
      "evmTransaction": 32,
      "overCeiling": [],
    })
  })

  it("orMask keeps field codes past 31", t =>
    t.expect({
      "code32": FieldMask.orMask(FieldMask.pow2(32), 1.),
      "code52": FieldMask.orMask(FieldMask.pow2(52), FieldMask.pow2(31)),
      "overlappingHighBits": FieldMask.orMask(
        FieldMask.pow2(40) +. FieldMask.pow2(33),
        FieldMask.pow2(33) +. 1.,
      ),
    }).toEqual({
      "code32": 4294967297.,
      "code52": 4503601774854144.,
      "overlappingHighBits": 1108101562369.,
    })
  )
})

describe("Transaction field-code contract", () => {
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
    t.expect(FieldMask.fieldCodes(["transactionIndex", "hash", "from"])).toEqual(
      dict{"transactionIndex": 0, "hash": 1, "from": 2},
    )
  })

  it("orMask combines field masks", t => {
    // A plain JS `|` renders bit 31 negative, so it's pinned with the rest.
    t.expect({
      "disjoint": FieldMask.orMask(1., 2.),
      "overlapping": FieldMask.orMask(3., 6.),
      "bit31WithLowBit": FieldMask.orMask(2147483648., 1.),
      "allBits": FieldMask.orMask(4294967295., 2147483648.),
    }).toEqual({
      "disjoint": 3.,
      "overlapping": 7.,
      "bit31WithLowBit": 2147483649.,
      "allBits": 4294967295.,
    })
  })
})
