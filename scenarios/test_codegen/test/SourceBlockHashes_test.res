open Vitest

let testApiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run SourceBlockHashes integration tests",
  )

// Ethereum mainnet.
let chain = ChainMap.Chain.makeUnsafe(~chainId=1)

// Uniswap V2 Factory's PairCreated event (topic0 = keccak("PairCreated(address,address,address,uint256)"))
// 2 indexed args (token0, token1) ⇒ topicCount = 3.
let pairCreatedTopic0 = "0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9"
let pairCreatedEventId = pairCreatedTopic0 ++ "_3"

// Lowercase address so EventRouter lookup matches regardless of whether the
// source returns checksummed or lowercase addresses.
let uniswapV2FactoryAddress =
  "0x5c69bee701ef814a2b6a3edd4b1652cb9cc5aa6f"->Address.unsafeFromString

// Build the event config by hand so topic0 stays the bare sighash. MockIndexer's
// evmEventConfig embeds its `id` (sighash_topicCount) directly as topic0, which
// is fine for unit tests against mocked sources but breaks real HyperSync queries.
// Block number and hash are needed so HyperSync returns block data for each item;
// otherwise blockHashes harvested from items would crash on undefined `block`.
let pairCreatedSelectedBlockFields = Utils.Set.fromArray(
  ([Number, Hash]: array<Internal.evmBlockField>),
)

let pairCreatedEventConfig: Internal.evmEventConfig = {
  id: pairCreatedEventId,
  contractName: "UniswapV2Factory",
  name: "PairCreated",
  paramsRawEventSchema: S.literal(%raw(`null`))
  ->S.shape(_ => ())
  ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
  simulateParamsSchema: S.unknown
  ->S.shape(_ => ())
  ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
  selectedBlockFields: pairCreatedSelectedBlockFields,
  selectedTransactionFields: Utils.Set.make(),
  transactionFieldMask: 0.,
  blockFieldMask: Evm.eventBlockFieldMask(
    pairCreatedSelectedBlockFields->(
      Utils.magic: Utils.Set.t<Internal.evmBlockField> => Utils.Set.t<string>
    ),
  ),
  sighash: pairCreatedTopic0,
  topicCount: 3,
  paramsMetadata: [],
}

let pairCreatedRegistration: Internal.evmOnEventRegistration = {
  id: 0,
  eventConfig: (pairCreatedEventConfig :> Internal.eventConfig),
  isWildcard: false,
  filterByAddresses: false,
  dependsOnAddresses: true,
  startBlock: None,
  handler: None,
  contractRegister: None,
  resolvedWhere: {
    topicSelections: [
      {
        topic0: [pairCreatedTopic0->EvmTypes.Hex.fromStringUnsafe],
        topic1: Values([]),
        topic2: Values([]),
        topic3: Values([]),
      },
    ],
    startBlock: None,
  },
}

// Match the on-chain ABI so the hypersync-client decoder doesn't raise
// UndefinedValue for valid logs. Non-wildcard event configs treat decode
// failures as fatal.
let pairCreatedAbi: array<Internal.paramMeta> = [
  {name: "token0", abiType: "address", indexed: true},
  {name: "token1", abiType: "address", indexed: true},
  {name: "pair", abiType: "address", indexed: false},
  {name: "allPairs", abiType: "uint256", indexed: false},
]

// The registration input mirrors pairCreatedRegistration, with the on-chain
// ABI attached so decoding works on real logs.
let pairCreatedEventRegistrations = EvmChain.collectEventRegistrations([
  pairCreatedRegistration,
])->Array.map(reg => {...reg, params: pairCreatedAbi})

let makeAddressesByContractName = () =>
  Dict.fromArray([("UniswapV2Factory", [uniswapV2FactoryAddress])])

let makeSelection = (): FetchState.selection => {
  onEventRegistrations: [(pairCreatedRegistration :> Internal.onEventRegistration)],
  dependsOnAddresses: true,
}

let makeHyperSyncSource = () =>
  HyperSyncSource.make({
    chain,
    endpointUrl: "https://eth.hypersync.xyz",
    eventRegistrations: pairCreatedEventRegistrations,
    onEventRegistrations: [pairCreatedRegistration],
    apiToken: Some(testApiToken),
    clientTimeoutMillis: Env.hyperSyncClientTimeoutMillis,
    lowercaseAddresses: true,
    serializationFormat: Env.hypersyncClientSerializationFormat,
    enableQueryCaching: false,
    logLevel: Env.hypersyncLogLevel,
  })

let makeRpcSource = () =>
  RpcSource.make({
    url: `https://eth.rpc.hypersync.xyz/${testApiToken}`,
    chain,
    onEventRegistrations: [pairCreatedRegistration],
    sourceFor: Sync,
    syncConfig: EvmChain.getSyncConfig({}),
    eventRegistrations: pairCreatedEventRegistrations,
    lowercaseAddresses: true,
  })

let invoke = async (source: Source.t, ~fromBlock, ~toBlock) => {
  try await source.getItemsOrThrow(
    ~fromBlock,
    ~toBlock=Some(toBlock),
    ~addressesByContractName=makeAddressesByContractName(),
    ~contractNameByAddress=FetchState.deriveContractNameByAddress(makeAddressesByContractName()),
    ~knownHeight=toBlock + 1000,
    ~partitionId="0",
    ~selection=makeSelection(),
    ~itemsTarget=5000,
    ~retry=0,
    ~logger=Logging.createChild(~params={"test": "SourceBlockHashes"}),
  ) catch {
  | Source.GetItemsError(err) =>
    let detail = switch err {
    | FailedGettingItems({exn}) =>
      switch exn {
      | JsExn(e) => e->JsExn.message->Option.getOr("(no message)")
      | _ => "(non-js exn)"
      }
    | _ => "(other err shape)"
    }
    JsError.throwWithMessage(`getItemsOrThrow failed: ${detail}`)
  }
}

let assertContainsBlockHash = (
  ~t: Vitest.testContext,
  ~blockHashes: array<ReorgDetection.blockData>,
  ~blockNumber,
  ~message,
) => {
  let found = blockHashes->Array.some(b => b.blockNumber === blockNumber)
  t.expect(found, ~message).toBe(true)
}

describe("Source.blockHashes integration - empty range", () => {
  // Uniswap V2 Factory was deployed at block 10000835. Anything well below that
  // is guaranteed to have zero matching PairCreated logs.
  let fromBlock = 100
  let toBlock = 110

  Async.itWithOptions(
    "HyperSync: empty parsedQueueItems and empty blockHashes for confirmed empty range",
    {retry: 3},
    async t => {
      let source = makeHyperSyncSource()
      let response = await source->invoke(~fromBlock, ~toBlock)

      t.expect({
        "parsedQueueItems": response.parsedQueueItems->Array.length,
        "blockHashes": response.blockHashes,
        "fromBlockQueried": response.fromBlockQueried,
      }).toEqual({
        "parsedQueueItems": 0,
        // No items, no rollbackGuard at historical depth → nothing to harvest.
        "blockHashes": [],
        "fromBlockQueried": fromBlock,
      })
    },
  )

  Async.itWithOptions(
    "RpcSource: empty parsedQueueItems but blockHashes still contains toBlock + parent",
    {retry: 3},
    async t => {
      let source = makeRpcSource()
      let response = await source->invoke(~fromBlock, ~toBlock)

      t.expect(response.parsedQueueItems->Array.length).toBe(0)

      // RpcSource always loads toBlock to get its timestamp, so its hash and the
      // parent hash are free.
      assertContainsBlockHash(
        ~t,
        ~blockHashes=response.blockHashes,
        ~blockNumber=toBlock,
        ~message="blockHashes must contain the latest fetched block (toBlock)",
      )
      assertContainsBlockHash(
        ~t,
        ~blockHashes=response.blockHashes,
        ~blockNumber=toBlock - 1,
        ~message="blockHashes must contain the parent of the latest fetched block",
      )
    },
  )
})

describe("Source.blockHashes integration - single-log range", () => {
  // Ethereum mainnet block 17915919 contains exactly one PairCreated event from
  // the Uniswap V2 Factory. Confirmed by hand against eth.rpc.hypersync.xyz.
  let fromBlock = 17915919
  let toBlock = 17915919
  let expectedBlockHash =
    "0xfae821f07390dab171f9487d9c25e7289c5d363fcc24f03b98de295aa621dca5"
  let expectedParentHash =
    "0x12a7ac0591fa50c8ee7e77cd38cac302286bdc57392a63ebb01b2859478f5752"

  Async.itWithOptions(
    "HyperSync: returns exactly one parsed item and a blockHashes entry for the matching block",
    {retry: 3},
    async t => {
      let source = makeHyperSyncSource()
      let response = await source->invoke(~fromBlock, ~toBlock)

      t.expect({
        "parsedQueueItems": response.parsedQueueItems->Array.length,
        "blockHashes": response.blockHashes,
        "latestFetchedBlockNumber": response.latestFetchedBlockNumber,
      }).toEqual({
        "parsedQueueItems": 1,
        "blockHashes": [
          (
            {
              ReorgDetection.blockNumber: fromBlock,
              blockHash: expectedBlockHash,
            }: ReorgDetection.blockData
          ),
        ],
        "latestFetchedBlockNumber": toBlock,
      })
    },
  )

  Async.itWithOptions(
    "RpcSource: returns exactly one parsed item; blockHashes carries toBlock + parent + the log's block",
    {retry: 3},
    async t => {
      let source = makeRpcSource()
      let response = await source->invoke(~fromBlock, ~toBlock)

      t.expect(response.parsedQueueItems->Array.length).toBe(1)
      t.expect(response.latestFetchedBlockNumber).toBe(toBlock)

      // toBlock entry comes from eth_getBlockByNumber; the log's block hash also
      // ends up in the array (and equals toBlock here since the range is one block).
      let toBlockEntry =
        response.blockHashes->Array.find(b => b.blockNumber === toBlock)->Option.getOrThrow
      let parentEntry =
        response.blockHashes->Array.find(b => b.blockNumber === toBlock - 1)->Option.getOrThrow
      t.expect({
        "toBlockHash": toBlockEntry.blockHash,
        "parentHash": parentEntry.blockHash,
      }).toEqual({
        "toBlockHash": expectedBlockHash,
        "parentHash": expectedParentHash,
      })
    },
  )
})
