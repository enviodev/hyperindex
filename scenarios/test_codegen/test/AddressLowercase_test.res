open Vitest

describe("Address lowercase helpers", () => {
  it("lowercases a valid address", t => {
    let input = "0x2C169DFe5fBbA12957Bdd0Ba47d9CEDbFE260CA7"
    let out = input->Address.Evm.fromStringLowercaseOrThrow->Address.toString
    t.expect(out).toBe("0x2c169dfe5fbba12957bdd0ba47d9cedbfe260ca7")
  })

  it("throws on invalid address", t => {
    t.expect(() => Address.Evm.fromStringLowercaseOrThrow("invalid-address")->ignore).toThrow()
  })

  it("fromAddressLowercaseOrThrow returns lowercase", t => {
    let mixed = Address.Evm.fromStringOrThrow("0x2c169dfe5fbba12957bdd0ba47d9cedbfe260ca7")
    let out = mixed->Address.Evm.fromAddressLowercaseOrThrow->Address.toString
    t.expect(out).toBe("0x2c169dfe5fbba12957bdd0ba47d9cedbfe260ca7")
  })

  // Regression: editor formatters that resolve unquoted YAML `0x…` as a hex
  // integer truncate the address through f64 on save, leaving 26+ trailing
  // zero hex chars. Must error at parse time with an actionable message
  // instead of silently passing a non-existent address downstream and
  // skipping every event.
  it("rejects an f64-truncated address with an actionable message", t => {
    let truncated = "0x1f9840A85D5aF600000000000000000000000000"
    let msg = try {
      let _ = Address.Evm.fromStringOrThrow(truncated)
      ""
    } catch {
    | JsExn(exn) => exn->JsExn.message->Option.getOr("")
    | _ => ""
    }
    t.expect(
      msg->String.includes("truncated"),
      ~message=`message must mention truncation, got: ${msg}`,
    ).toBe(true)
  })

  it("accepts the all-zero address (no false positive on burn address)", t => {
    let zero = "0x0000000000000000000000000000000000000000"
    let out = Address.Evm.fromStringLowercaseOrThrow(zero)->Address.toString
    t.expect(out).toBe(zero)
  })

  it("accepts a lowercase address with 25 trailing zeros (under the threshold)", t => {
    let addr = "0x1f9840a85d5af5bf1d1762f9000000000000000a"
    let out = addr->Address.Evm.fromStringLowercaseOrThrow->Address.toString
    t.expect(out).toBe(addr)
  })
})
