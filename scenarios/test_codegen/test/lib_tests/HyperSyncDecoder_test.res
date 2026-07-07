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

// A crafted log as (topics, data); fed to a mock eth_getLogs endpoint and
// decoded through EvmRpcClient.
let decodeSingle = async (
  ~eventName: string,
  ~params: array<Internal.paramMeta>,
  ~log: (array<string>, string),
) => {
  let sighash = toEventSelector(
    `event ${eventName}(${params
      ->Array.map(p => p.indexed ? `${p.abiType} indexed` : p.abiType)
      ->Array.joinUnsafe(", ")})`,
  )
  let topicCount = params->Array.reduce(1, (acc, p) => p.indexed ? acc + 1 : acc)
  let decoded = await NativeDecoder.decodeLogs(
    ~eventParams=[{sighash, topicCount, eventName, contractName: "TestContract", params}],
    ~logs=[log],
  )
  decoded[0]
  ->Option.getUnsafe
  ->Nullable.toOption
  ->Option.getUnsafe
  ->Dict.getUnsafe("TestContract")
}

let allIndexedLog = (
  [
    sighash,
    fromAddr->pad,
    toAddr->pad,
    Viem.bigintToHex(value, ~options={size: 32})->(Utils.magic: Viem.hex => string),
  ],
  "0x",
)

let noneIndexedLog = (
  [sighash],
  encodeAbiParameters(
    %raw(`[{"type":"address"},{"type":"address"},{"type":"uint256"}]`),
    %raw(`["0x000000000000000000000000000000000000aaaa","0x000000000000000000000000000000000000bbbb",42n]`),
  ),
)

describe("EVM event decoding via EvmRpcClient.getLogs", () => {
  Async.it("produces named params directly for different indexed layouts", async t => {
    let decoded = await NativeDecoder.decodeLogs(
      ~eventParams=[
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
      ],
      ~logs=[allIndexedLog, noneIndexedLog],
    )

    let pick = i =>
      decoded[i]
      ->Option.getUnsafe
      ->Nullable.toOption
      ->Option.getUnsafe
      ->Dict.getUnsafe("TestContract")
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
      ~log=(
        [sighash, "0xabc"->pad, "0xdef"->pad],
        encodeAbiParameters(%raw(`[{"type":"uint256"}]`), %raw(`[100n]`)),
      ),
    )
    t
    .expect(result)
    .toEqual(
      {
        "from": "0x0000000000000000000000000000000000000abc",
        "to": "0x0000000000000000000000000000000000000def",
        "value": 100n,
      }->Utils.magic,
    )
  })

  Async.it("handles empty params", async t => {
    let decoded = await NativeDecoder.decodeLogs(
      ~eventParams=[
        {
          sighash: toEventSelector("event Empty()"),
          topicCount: 1,
          eventName: "Empty",
          contractName: "TestContract",
          params: [],
        },
      ],
      ~logs=[([toEventSelector("event Empty()")], "0x")],
    )
    let result =
      decoded[0]
      ->Option.getUnsafe
      ->Nullable.toOption
      ->Option.getUnsafe
      ->Dict.getUnsafe("TestContract")
    t.expect(result).toEqual(%raw(`{}`))
  })

  // Regression for https://github.com/enviodev/hyperindex/issues/1353
  // The native decoder returns an empty object `{}` for a zero-parameter event,
  // which the ecosystem's toRawEvent must serialize for the raw_events table
  // without crashing the batch write.
  Async.it("toRawEvent serializes empty params decoded by native decoder", async t => {
    let params = await decodeSingle(
      ~eventName="Empty",
      ~params=[],
      ~log=([toEventSelector("event Empty()")], "0x"),
    )
    t.expect(params).toEqual(%raw(`{}`))

    let srcAddress =
      "0x00000000000000000000000000000000000000ab"->(Utils.magic: string => Address.t)
    let blockNumber = 5
    let logIndex = 3

    let payload =
      {
        "block": %raw(`{"number": 5, "timestamp": 9999, "hash": "0xblockhash", "gasUsed": 99n, "miner": "0xminer"}`),
        "transaction": %raw(`{"hash": "0xtxhash", "transactionIndex": 2}`),
        "params": params,
        "logIndex": logIndex,
        "srcAddress": srcAddress,
        "chainId": 137,
        "contractName": "ERC20",
        "eventName": "EventWithoutFields",
      }->(Utils.magic: {..} => Internal.eventPayload)

    let eventItem =
      Internal.Event({
        onEventRegistration: (MockIndexer.evmOnEventRegistration(~contractName="ERC20") :> Internal.onEventRegistration),
        timestamp: 1234,
        chain: ChainMap.Chain.makeUnsafe(~chainId=137),
        blockNumber,
        blockHash: "0xblockhash",
        logIndex,
        transactionIndex: 0,
        payload,
      })->Internal.castUnsafeEventItem

    t.expect(MockIndexer.config.ecosystem.toRawEvent(eventItem)).toEqual({
      chain_id: 137,
      event_id: EventUtils.packEventIndex(~logIndex, ~blockNumber),
      event_name: "EventWithoutFields",
      contract_name: "ERC20",
      block_number: blockNumber,
      log_index: logIndex,
      src_address: srcAddress,
      block_hash: "0xblockhash",
      block_timestamp: 1234,
      block_fields: %raw(`{"gasUsed": "99", "miner": "0xminer"}`),
      transaction_fields: %raw(`{"hash": "0xtxhash", "transactionIndex": 2}`),
      params: %raw(`"null"`),
    })
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
        ~log=(
          [
            toEventSelector(
              "event VehicleCreated(address indexed, address, (address,address,address[],uint256,address))",
            ),
            "0x00000000000000000000000000000000000000aa"->pad,
          ],
          encodeAbiParameters(
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
      ~log=(
        [toEventSelector("event MixedEvent((string,uint256,address,bool))")],
        encodeAbiParameters(
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
      ~log=([toEventSelector("event StructEvent((address,uint256) indexed)"), topicHash], "0x"),
    )

    t
    .expect(result)
    .toEqual({"indexedStruct": topicHash}->Utils.magic)
  })
})
