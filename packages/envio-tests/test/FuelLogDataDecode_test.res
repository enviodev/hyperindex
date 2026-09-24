open Vitest

let u64 = n => [0, 0, 0, 0, 0, 0, 0, n]
let u32 = n => [0, 0, 0, n]
let toUnknown = (value: 'a): unknown => value->(Utils.magic: 'a => unknown)

let decode = (logId, bytes) =>
  Core.getAddon().decodeFuelLogDataForTest(
    ~abi=FuelAbiFixtures.allEvents->JSON.parseOrThrow,
    ~logId,
    ~data=Uint8Array.fromArray(bytes),
  )->toUnknown

describe("Fuel LogData decoding", () => {
  // The shapes the vendored @fuel-ts/abi-coder patch produced, which the
  // generated ReScript types are tagged on: enums (Option included) as
  // `{case, payload}` with an undefined payload for unit variants, u64 and
  // wider as bigint, Bytes as Uint8Array.
  it("hands handlers the JS values the previous JS decoder produced", t => {
    t.expect([
      decode("3330666440490685604", []),
      decode("10927802446890217233", u64(0)),
      decode("10927802446890217233", Array.concat(u64(1), u32(12))),
      decode("8688528864679113840", Array.concat(u64(1), u64(0))),
      decode("7417129983252335614", u64(0)),
      decode("7417129983252335614", Array.concat(u64(2), u32(1))),
      decode("3525891009499019808", Array.concat(u32(11), Array.concat(u64(1), u32(32)))),
      decode("15402277555065905665", Array.concat(u64(2), Array.concat(u64(69), u64(23)))),
      decode("14832741149864513620", Array.concat(u64(1), [40])),
      decode("8961848586872524460", Array.make(~length=31, 0)->Array.concat([1])),
      decode("11132648958528852192", Array.concat(u64(4), [97, 98, 99, 100])),
      decode("14454674236531057292", [3, 0]),
    ]).toStrictEqual([
      ()->toUnknown,
      {"case": "None", "payload": ()}->toUnknown,
      {"case": "Some", "payload": 12}->toUnknown,
      {"case": "Some", "payload": {"case": "None", "payload": ()}}->toUnknown,
      {"case": "Pending", "payload": ()}->toUnknown,
      {"case": "Failed", "payload": {"reason": 1}}->toUnknown,
      {"f1": 11, "f2": {"case": "Some", "payload": 32}}->toUnknown,
      [69n, 23n]->toUnknown,
      Uint8Array.fromArray([40])->toUnknown,
      "0x0000000000000000000000000000000000000000000000000000000000000001"->toUnknown,
      "abcd"->toUnknown,
      // A trailing byte past the logged u8: rejected, so routing drops it.
      Null.null->toUnknown,
    ])
  })
})
