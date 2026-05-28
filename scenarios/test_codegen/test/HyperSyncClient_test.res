open Vitest

let testApiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run HyperSyncClient tests",
  )

// USDC on Ethereum mainnet. The Transfer event is the most common event on
// chain — this 5-block range almost certainly contains hits and the response
// shape is stable.
let usdcAddress =
  "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"->Address.unsafeFromString

let transferSighash =
  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

let transferParams: array<Internal.paramMeta> = [
  {name: "from", abiType: "address", indexed: true},
  {name: "to", abiType: "address", indexed: true},
  {name: "value", abiType: "uint256", indexed: false},
]

let transferEventParam: HyperSyncClient.Decoder.eventParamsInput = {
  sighash: transferSighash,
  topicCount: 3,
  eventName: "Transfer",
  params: transferParams,
}

let makeClient = (~eventParams) =>
  HyperSyncClient.make(
    ~url="https://eth.hypersync.xyz",
    ~apiToken=testApiToken,
    ~maxNumRetries=Env.hyperSyncClientMaxRetries,
    ~httpReqTimeoutMillis=Env.hyperSyncClientTimeoutMillis,
    ~eventParams,
    ~enableChecksumAddresses=false,
  )

let fromBlock = 23_500_000
let toBlock = 23_500_004

let runQuery = async (~client: HyperSyncClient.t) =>
  await client.getEventItems(
    ~query={
      fromBlock,
      toBlockExclusive: toBlock + 1,
      logs: [
        {
          address: [usdcAddress],
          topics: HyperSyncClient.QueryTypes.makeTopicSelection(
            ~topic0=[transferSighash->EvmTypes.Hex.fromStringUnsafe],
          ),
        },
      ],
      fieldSelection: {
        log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
        block: [Number, Hash, Timestamp],
        transaction: [Hash, From, To],
      },
    },
  )

describe("HyperSync client getEventItems (live)", () => {
  Async.it(
    "returns event items with decoded params for a real block range",
    async t => {
      let client = makeClient(~eventParams=[transferEventParam])
      let res = await runQuery(~client)

      t.expect(res.items->Array.length > 0).toBe(true)

      let first = res.items->Array.getUnsafe(0)

      // Flattened item: pre-unwrapped src address, separate topic0 + count
      t.expect(first.srcAddress->Address.toString->String.length).toBe(42)
      t.expect(first.topicCount).toBe(3)
      t.expect(first.topic0->EvmTypes.Hex.toString).toBe(transferSighash)

      // Block fields all populated
      let block = first.block
      t.expect(block.number->Option.isSome).toBe(true)
      t.expect(block.hash->Option.isSome).toBe(true)
      t.expect(block.timestamp->Option.isSome).toBe(true)
      let blockNumber = block.number->Option.getUnsafe
      t.expect(blockNumber >= fromBlock && blockNumber <= toBlock).toBe(true)

      // Transaction
      t.expect(first.transaction.hash->Option.isSome).toBe(true)

      // Decoded params present and well-shaped
      switch first.params->Nullable.toOption {
      | Some(params) =>
        let asObj = params->(Utils.magic: Internal.eventParams => {..})
        t
          .expect(asObj["from"]->(Utils.magic: 'a => string)->String.length)
          .toBe(42)
        t
          .expect(asObj["to"]->(Utils.magic: 'a => string)->String.length)
          .toBe(42)
        t
          .expect(asObj["value"]->(Utils.magic: 'a => bigint) >= 0n)
          .toBe(true)
      | None => t.expect(false).toBe(true) // fail: should have decoded
      }

      // Pagination cursor
      t.expect(res.nextBlock > fromBlock).toBe(true)
      t
        .expect(res.archiveHeight->Option.getOr(0) >= res.nextBlock)
        .toBe(true)
    },
  )

  Async.it(
    "leaves params null when topic0 doesn't match any registered signature",
    async t => {
      // Register a different sighash; the Transfer logs we fetch won't match.
      let unrelatedEventParam: HyperSyncClient.Decoder.eventParamsInput = {
        sighash: "0x0000000000000000000000000000000000000000000000000000000000000001",
        topicCount: 1,
        eventName: "Unrelated",
        params: [],
      }
      let client = makeClient(~eventParams=[unrelatedEventParam])
      let res = await runQuery(~client)

      t.expect(res.items->Array.length > 0).toBe(true)
      let first = res.items->Array.getUnsafe(0)
      t.expect(first.params->Nullable.toOption->Option.isNone).toBe(true)
    },
  )
})
