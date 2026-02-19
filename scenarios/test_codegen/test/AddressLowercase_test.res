open Vitest

describe("Address lowercase helpers", () => {
  it("lowercases a valid address", () => {
    let input = "0x2C169DFe5fBbA12957Bdd0Ba47d9CEDbFE260CA7"
    let out = input->Address.Evm.fromStringLowercaseOrThrow->Address.toString
    Assert.strictEqual(out, "0x2c169dfe5fbba12957bdd0ba47d9cedbfe260ca7")
  })

  it("throws on invalid address", () => {
    Assert.throws(() => Address.Evm.fromStringLowercaseOrThrow("invalid-address")->ignore)
  })

  it("fromAddressLowercaseOrThrow returns lowercase", () => {
    let mixed = Address.Evm.fromStringOrThrow("0x2c169dfe5fbba12957bdd0ba47d9cedbfe260ca7")
    let out = mixed->Address.Evm.fromAddressLowercaseOrThrow->Address.toString
    Assert.strictEqual(out, "0x2c169dfe5fbba12957bdd0ba47d9cedbfe260ca7")
  })
})