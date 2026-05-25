open Vitest

@module("viem")
external encodeAbiParameters: (JSON.t, JSON.t) => string = "encodeAbiParameters"

@module("viem")
external toEventSelector: string => string = "toEventSelector"

@module("viem") external pad: string => string = "pad"

let sigAllIndexed = "Transfer(address indexed from, address indexed to, uint256 indexed value)"
let sigNoneIndexed = "Transfer(address from, address to, uint256 value)"

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

describe("HyperSync decoder – same sighash, different indexed layouts", () => {
  Async.it("native decoder correctly splits indexed vs body for both layouts", async t => {
    let decoder = HyperSyncClient.Decoder.fromSignatures(
      [sigAllIndexed, sigNoneIndexed],
    )
    let decoded = await decoder.decodeEvents([allIndexedLog, noneIndexedLog])

    let decodedAll = decoded[0]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe
    let decodedNone = decoded[1]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe

    t.expect((decodedAll.indexed->Array.length, decodedAll.body->Array.length)).toEqual((3, 0))
    t.expect((decodedNone.indexed->Array.length, decodedNone.body->Array.length)).toEqual((0, 3))
  })

  Async.it(
    "end-to-end: convertHyperSyncEventArgs produces correct named params for both layouts",
    async t => {
      let decoder = HyperSyncClient.Decoder.fromSignatures(
        [sigAllIndexed, sigNoneIndexed],
      )
      let decoded = await decoder.decodeEvents([allIndexedLog, noneIndexedLog])

      let decodedAll = decoded[0]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe
      let decodedNone = decoded[1]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe

      let allIndexedParams: array<EventConfigBuilder.eventParam> = [
        {name: "from", abiType: "address", indexed: true},
        {name: "to", abiType: "address", indexed: true},
        {name: "value", abiType: "uint256", indexed: true},
      ]
      let noneIndexedParams: array<EventConfigBuilder.eventParam> = [
        {name: "from", abiType: "address", indexed: false},
        {name: "to", abiType: "address", indexed: false},
        {name: "value", abiType: "uint256", indexed: false},
      ]

      let convertAll = EventConfigBuilder.buildHyperSyncDecoder(allIndexedParams)
      let convertNone = EventConfigBuilder.buildHyperSyncDecoder(noneIndexedParams)

      let paramsAll = convertAll(decodedAll)
      let paramsNone = convertNone(decodedNone)

      let expected =
        {"from": fromAddr, "to": toAddr, "value": value}->(
          Utils.magic: {..} => Internal.eventParams
        )
      t.expect(paramsAll).toEqual(expected)
      t.expect(paramsNone).toEqual(expected)
    },
  )
})
