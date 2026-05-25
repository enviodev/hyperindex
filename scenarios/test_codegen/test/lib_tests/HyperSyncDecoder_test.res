open Vitest

@module("viem")
external encodeAbiParameters: (JSON.t, JSON.t) => string = "encodeAbiParameters"

@module("viem")
external toEventSelector: string => string = "toEventSelector"

@module("viem") external pad: string => string = "pad"

let sighash = toEventSelector("event Transfer(address, address, uint256)")

let fromAddr = "0x000000000000000000000000000000000000aaaa"
let toAddr = "0x000000000000000000000000000000000000bbbb"
let value = 42n

let makeEvent = (~topics: array<string>, ~data: string): HyperSyncClient.ResponseTypes.event =>
  {"log": {"topics": topics, "data": data}}->(
    Utils.magic: {..} => HyperSyncClient.ResponseTypes.event
  )

let allIndexedLog = makeEvent(
  ~topics=[
    sighash,
    fromAddr->pad,
    toAddr->pad,
    Viem.bigintToHex(value, ~options={size: 32})->(Utils.magic: Viem.hex => string),
  ],
  ~data="0x",
)

let noneIndexedLog = makeEvent(
  ~topics=[sighash],
  ~data=encodeAbiParameters(
    %raw(`[{"type":"address"},{"type":"address"},{"type":"uint256"}]`),
    %raw(`["0x000000000000000000000000000000000000aaaa","0x000000000000000000000000000000000000bbbb",42n]`),
  ),
)

describe("HyperSync decoder – fromParams + decodeLogs", () => {
  Async.it("produces named params directly for different indexed layouts", async t => {
    let decoder = HyperSyncClient.Decoder.fromParams([
      {
        sighash,
        topicCount: 4,
        eventName: "Transfer",
        params: [
          {name: "from", abiType: "address", indexed: true},
          {name: "to", abiType: "address", indexed: true},
          {name: "value", abiType: "uint256", indexed: true},
        ],
      },
      {
        sighash,
        topicCount: 1,
        eventName: "Transfer",
        params: [
          {name: "from", abiType: "address", indexed: false},
          {name: "to", abiType: "address", indexed: false},
          {name: "value", abiType: "uint256", indexed: false},
        ],
      },
    ])

    let decoded = await decoder.decodeLogs([allIndexedLog, noneIndexedLog])

    let paramsAll = decoded[0]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe
    let paramsNone = decoded[1]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe

    let expected = {"from": fromAddr, "to": toAddr, "value": value}->Utils.magic
    t.expect(paramsAll).toEqual(expected)
    t.expect(paramsNone).toEqual(expected)
  })
})
