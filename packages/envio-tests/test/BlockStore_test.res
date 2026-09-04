open Vitest

describe("BlockStore field-code contract", () => {
  // The selection mask is built in ReScript from this array's order and decoded
  // in Rust by EvmBlockField ordinal, so a drift silently materialises the wrong
  // field. Pin both against the Rust ordering (the source of truth).
  it("EVM blockFields match the Rust EvmBlockField order", t => {
    t.expect(Evm.blockFields).toEqual(Core.getAddon().evmBlockFieldNames())
  })

  it("SVM blockFields match the Rust SvmBlockField order", t => {
    t.expect(Svm.blockFields).toEqual(Core.getAddon().svmBlockFieldNames())
  })

  it("Fuel blockFields match the Rust FuelBlockField order", t => {
    t.expect(Fuel.blockFields).toEqual(Core.getAddon().fuelBlockFieldNames())
  })
})
