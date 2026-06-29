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

let decodeSingle = async (
  ~eventName: string,
  ~params: array<Internal.paramMeta>,
  ~event: HyperSyncClient.ResponseTypes.event,
) => {
  let sighash = toEventSelector(
    `event ${eventName}(${params->Array.map(p => p.indexed ? `${p.abiType} indexed` : p.abiType)->Array.joinUnsafe(", ")})`,
  )
  let topicCount = params->Array.reduce(1, (acc, p) => p.indexed ? acc + 1 : acc)
  let decoder = HyperSyncClient.Decoder.fromParams([
    {sighash, topicCount, eventName, contractName: "TestContract", params},
  ])
  let decoded = await decoder.decodeLogs([event])
  decoded[0]
  ->Option.getUnsafe
  ->Nullable.toOption
  ->Option.getUnsafe
  ->Dict.getUnsafe("TestContract")
}

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
        contractName: "TestContract",
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
        contractName: "TestContract",
        params: [
          {name: "from", abiType: "address", indexed: false},
          {name: "to", abiType: "address", indexed: false},
          {name: "value", abiType: "uint256", indexed: false},
        ],
      },
    ])

    let decoded = await decoder.decodeLogs([allIndexedLog, noneIndexedLog])

    let pick = i =>
      decoded[i]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe->Dict.getUnsafe("TestContract")
    let paramsAll = pick(0)
    let paramsNone = pick(1)

    let expected = {"from": fromAddr, "to": toAddr, "value": value}->Utils.magic
    t.expect(paramsAll).toEqual(expected)
    t.expect(paramsNone).toEqual(expected)
  })

  Async.it("produces correct field names", async t => {
    let params: array<Internal.paramMeta> = [
      {name: "from", abiType: "address", indexed: true},
      {name: "to", abiType: "address", indexed: true},
      {name: "value", abiType: "uint256", indexed: false},
    ]
    let result = await decodeSingle(
      ~eventName="Transfer",
      ~params,
      ~event=makeEvent(
        ~topics=[
          sighash,
          "0xabc"->pad,
          "0xdef"->pad,
        ],
        ~data=encodeAbiParameters(
          %raw(`[{"type":"uint256"}]`),
          %raw(`[100n]`),
        ),
      ),
    )
    t.expect(result).toEqual({"from": "0x0000000000000000000000000000000000000abc", "to": "0x0000000000000000000000000000000000000def", "value": 100n}->Utils.magic)
  })

  Async.it("handles empty params", async t => {
    let decoder = HyperSyncClient.Decoder.fromParams([
      {
        sighash: toEventSelector("event Empty()"),
        topicCount: 1,
        eventName: "Empty",
        contractName: "TestContract",
        params: [],
      },
    ])
    let decoded = await decoder.decodeLogs([
      makeEvent(~topics=[toEventSelector("event Empty()")], ~data="0x"),
    ])
    let result =
      decoded[0]
      ->Option.getUnsafe
      ->Nullable.toOption
      ->Option.getUnsafe
      ->Dict.getUnsafe("TestContract")
    t.expect(result).toEqual(%raw(`{}`))
  })

  // Reproduction for https://github.com/enviodev/hyperindex/issues/1353
  // With raw_events enabled, a zero-parameter event crashes the batch write.
  // The native decoder returns an empty object `{}` for such events (see the
  // "handles empty params" test above), and RawEvent.make serializes those
  // params via paramsRawEventSchema. buildParamsSchema([]) builds a schema
  // expecting unit/`null`, so the reverse conversion throws
  // "Expected undefined, received {}" on the real decoder output.
  Async.it("paramsRawEventSchema serializes empty params decoded by native decoder", async t => {
    let params: array<Internal.paramMeta> = []
    let schema = EventConfigBuilder.buildParamsSchema(params)

    let result = await decodeSingle(
      ~eventName="Empty",
      ~params,
      ~event=makeEvent(~topics=[toEventSelector("event Empty()")], ~data="0x"),
    )
    t.expect(result).toEqual(%raw(`{}`))

    let json = result->S.reverseConvertToJsonOrThrow(schema)
    t.expect(json).toEqual(%raw(`null`))
  })

  Async.it(
    "paramsRawEventSchema serializes struct/tuple params decoded by native decoder",
    async t => {
      let params: array<Internal.paramMeta> = [
        {name: "deployer", abiType: "address", indexed: true},
        {name: "vehicle", abiType: "address", indexed: false},
        {
          name: "params",
          abiType: "(address,address,address[],uint256,address)",
          indexed: false,
          components: [
            {name: "asset", abiType: "address", indexed: false},
            {name: "poolAddressesProvider", abiType: "address", indexed: false},
            {name: "forbiddenAddresses", abiType: "address[]", indexed: false},
            {name: "initialExpectedSupply", abiType: "uint256", indexed: false},
            {name: "registry", abiType: "address", indexed: false},
          ],
        },
      ]

      let schema = EventConfigBuilder.buildParamsSchema(params)

      let result = await decodeSingle(
        ~eventName="VehicleCreated",
        ~params,
        ~event=makeEvent(
          ~topics=[
            toEventSelector(
              "event VehicleCreated(address indexed, address, (address,address,address[],uint256,address))",
            ),
            "0x00000000000000000000000000000000000000aa"->pad,
          ],
          ~data=encodeAbiParameters(
            %raw(`[{"type":"address"},{"type":"tuple","components":[{"type":"address"},{"type":"address"},{"type":"address[]"},{"type":"uint256"},{"type":"address"}]}]`),
            %raw(`["0x0000000000000000000000000000000000000001",["0x0000000000000000000000000000000000000002","0x0000000000000000000000000000000000000003",["0x0000000000000000000000000000000000000004","0x0000000000000000000000000000000000000005"],1000n,"0x0000000000000000000000000000000000000006"]]`),
          ),
        ),
      )

      t
        .expect(result)
        .toEqual(
          {
            "deployer": "0x00000000000000000000000000000000000000aa",
            "vehicle": "0x0000000000000000000000000000000000000001",
            "params": {
              "asset": "0x0000000000000000000000000000000000000002",
              "poolAddressesProvider": "0x0000000000000000000000000000000000000003",
              "forbiddenAddresses": [
                "0x0000000000000000000000000000000000000004",
                "0x0000000000000000000000000000000000000005",
              ],
              "initialExpectedSupply": 1000n,
              "registry": "0x0000000000000000000000000000000000000006",
            },
          }->Utils.magic,
        )

      let json = result->S.reverseConvertToJsonOrThrow(schema)
      t
        .expect(json)
        .toEqual(
          %raw(`{
        "deployer": "0x00000000000000000000000000000000000000aa",
        "vehicle": "0x0000000000000000000000000000000000000001",
        "params": {
          "asset": "0x0000000000000000000000000000000000000002",
          "poolAddressesProvider": "0x0000000000000000000000000000000000000003",
          "forbiddenAddresses": ["0x0000000000000000000000000000000000000004", "0x0000000000000000000000000000000000000005"],
          "initialExpectedSupply": "1000",
          "registry": "0x0000000000000000000000000000000000000006"
        }
      }`),
        )
    },
  )

  Async.it("remaps mixed-name tuple components using index keys", async t => {
    let params: array<Internal.paramMeta> = [
      {
        name: "mixed",
        abiType: "(string,uint256,address,bool)",
        indexed: false,
        components: [
          {name: "label", abiType: "string", indexed: false},
          {name: "1", abiType: "uint256", indexed: false},
          {name: "recipient", abiType: "address", indexed: false},
          {name: "3", abiType: "bool", indexed: false},
        ],
      },
    ]

    let result = await decodeSingle(
      ~eventName="MixedEvent",
      ~params,
      ~event=makeEvent(
        ~topics=[toEventSelector("event MixedEvent((string,uint256,address,bool))")],
        ~data=encodeAbiParameters(
          %raw(`[{"type":"tuple","components":[{"type":"string"},{"type":"uint256"},{"type":"address"},{"type":"bool"}]}]`),
          %raw(`[["hi", 42n, "0x0000000000000000000000000000000000000abc", true]]`),
        ),
      ),
    )

    t
      .expect(result)
      .toEqual(
        {
          "mixed": {
            "label": "hi",
            "1": 42n,
            "recipient": "0x0000000000000000000000000000000000000abc",
            "3": true,
          },
        }->Utils.magic,
      )
  })

  Async.it("leaves indexed struct params as topic hashes", async t => {
    let params: array<Internal.paramMeta> = [
      {
        name: "indexedStruct",
        abiType: "(address,uint256)",
        indexed: true,
        components: [
          {name: "owner", abiType: "address", indexed: false},
          {name: "amount", abiType: "uint256", indexed: false},
        ],
      },
    ]
    let topicHash = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

    let result = await decodeSingle(
      ~eventName="StructEvent",
      ~params,
      ~event=makeEvent(
        ~topics=[
          toEventSelector("event StructEvent((address,uint256) indexed)"),
          topicHash,
        ],
        ~data="0x",
      ),
    )

    t
      .expect(result)
      .toEqual({"indexedStruct": topicHash}->Utils.magic)
  })
})
