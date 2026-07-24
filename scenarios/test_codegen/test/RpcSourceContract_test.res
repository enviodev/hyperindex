open Vitest

type sourceFactory = RpcSource.options => Source.t

let chain = ChainMap.Chain.makeUnsafe(~chainId=1)
let sighash = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f"
let transactionHash = "0x27e26f21f744064a4af53810d8002bbd7208a2ca4865503a99b9c529e5cff5ea"
let contractAddress = "0x00000000000000000000000000000000000000AA"
let normalizedContractAddress = contractAddress->String.toLowerCase
let fromAddress = "0x00000000000000000000000000000000000000BB"
let normalizedFromAddress = fromAddress->String.toLowerCase
let minerAddress = "0x00000000000000000000000000000000000000CC"
let normalizedMinerAddress = minerAddress->String.toLowerCase
let address = normalizedContractAddress->Address.unsafeFromString

let topicSelection: Internal.resolvedTopicSelection = {
  topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
  topic1: Values([]),
  topic2: Values([]),
  topic3: Values([]),
}

let withPinIdentity = (registration: Internal.evmOnEventRegistration, ~index) => {
  let eventConfig = registration.eventConfig->(
    Utils.magic: Internal.eventConfig => Internal.evmEventConfig
  )
  {
    ...registration,
    index,
    eventConfig: ({...eventConfig, id: `${sighash}_1`, sighash} :> Internal.eventConfig),
  }
}

let makeRegistration = (~index=0, ~receiptOnly=false) => {
  MockIndexer.evmOnEventRegistration(
    ~id=sighash,
    ~blockFieldNames=[Number, Timestamp, Hash, ParentHash, GasUsed, Miner],
    ~transactionFieldNames=receiptOnly
      ? [GasUsed]
      : [Hash, TransactionIndex, From, Gas, GasUsed, Status],
    ~eventFilters=[topicSelection],
  )->withPinIdentity(~index)
}

let makeRoutingRegistration = (
  ~index=0,
  ~contractName="ERC20",
  ~isWildcard=false,
  ~eventFilters=[topicSelection],
  // topicCount is derived from paramsMetadata inside evmOnEventRegistration.
  ~paramsMetadata: array<Internal.paramMeta>=[],
) => {
  MockIndexer.evmOnEventRegistration(
    ~id=sighash,
    ~contractName,
    ~blockFieldNames=[Number],
    ~isWildcard,
    ~eventFilters,
    ~paramsMetadata,
  )->withPinIdentity(~index)
}

let syncConfig = EvmChain.getSyncConfig({
  initialBlockInterval: 1,
  accelerationAdditive: 0,
  intervalCeiling: 1,
  backoffMillis: 1,
  queryTimeoutMillis: 1_000,
})

let makeSource = (~factory, ~url, ~registration: Internal.evmOnEventRegistration) => {
  let options: RpcSource.options = {
    url,
    chain,
    onEventRegistrations: [registration],
    sourceFor: Sync,
    syncConfig,
    lowercaseAddresses: true,
  }
  factory(options)
}

let invoke = (source: Source.t, ~registration: Internal.evmOnEventRegistration, ~retry=0) => {
  let addressesByContractName = Dict.fromArray([
    (registration.eventConfig.contractName, [address]),
  ])
  source.getItemsOrThrow(
    ~fromBlock=100,
    ~toBlock=Some(100),
    ~addressesByContractName,
    ~contractNameByAddress=FetchState.deriveContractNameByAddress(addressesByContractName),
    ~knownHeight=100,
    ~partitionId="pin-partition",
    ~selection={
      dependsOnAddresses: true,
      onEventRegistrations: [(registration :> Internal.onEventRegistration)],
    },
    ~itemsTarget=Some(5_000),
    ~retry,
    ~logger=Logging.createChild(~params={"test": "RPC source contract pin"}),
  )
}

let getLogsParams = (~toBlock="0x64") =>
  JSON.parseOrThrow(
    `[{"fromBlock":"0x64","toBlock":"${toBlock}","topics":[["${sighash}"]],"address":["${normalizedContractAddress}"]}]`,
  )

let blockParams = hex => JSON.parseOrThrow(`["${hex}",false]`)

let block99 = JSON.parseOrThrow(
  `{"number":"0x63","timestamp":"0x63","hash":"0xb63","parentHash":"0xb62","gasUsed":"0x1","miner":"${minerAddress}"}`,
)

let block100 = JSON.parseOrThrow(
  `{"number":"0x64","timestamp":"0x64","hash":"0xb64","parentHash":"0xb63","gasUsed":"0x5208","miner":"${minerAddress}"}`,
)

let log = (~logIndex) =>
  JSON.parseOrThrow(
    `{"address":"${contractAddress}","topics":["${sighash}"],"data":"0x","blockNumber":"0x64","transactionHash":"${transactionHash}","transactionIndex":"0x1","blockHash":"0xb64","logIndex":"${logIndex}","removed":false}`,
  )

let transaction = JSON.parseOrThrow(
  `{"from":"${fromAddress}","gas":"0x7530"}`,
)

let receipt = JSON.parseOrThrow(`{"gasUsed":"0x5208","status":"0x1"}`)

let successfulCalls = (~times=1, ~logs=[log(~logIndex="0x2"), log(~logIndex="0x3")]) => [
  MockRpcServer.expectCall(
    ~label="logs",
    ~method="eth_getLogs",
    ~params=getLogsParams(),
    ~reply=RpcResult(JSON.Array(logs)),
    ~times,
  ),
  MockRpcServer.expectCall(
    ~label="parent block",
    ~method="eth_getBlockByNumber",
    ~params=blockParams("0x63"),
    ~reply=RpcResult(block99),
    ~times,
  ),
  MockRpcServer.expectCall(
    ~label="latest and event block",
    ~method="eth_getBlockByNumber",
    ~params=blockParams("0x64"),
    ~reply=RpcResult(block100),
    ~times,
  ),
  MockRpcServer.expectCall(
    ~label="transaction",
    ~method="eth_getTransactionByHash",
    ~params=JSON.Array([JSON.String(transactionHash)]),
    ~reply=RpcResult(transaction),
    ~times,
  ),
  MockRpcServer.expectCall(
    ~label="receipt",
    ~method="eth_getTransactionReceipt",
    ~params=JSON.Array([JSON.String(transactionHash)]),
    ~reply=RpcResult(receipt),
    ~times,
  ),
]

type blockView = {
  number: int,
  timestamp: int,
  hash: string,
  parentHash: string,
  gasUsed: bigint,
  miner: Address.t,
}

type transactionView = {
  hash: string,
  transactionIndex: int,
  from: Address.t,
  gas: bigint,
  gasUsed: bigint,
  status: int,
}

let eventSummary = (event: RpcSourcePins.pinnedEvent) => {
  let block = event.block->Option.getOrThrow->(Utils.magic: Internal.eventBlock => blockView)
  let transaction = event.transaction
  ->Option.getOrThrow
  ->(Utils.magic: Internal.eventTransaction => transactionView)
  {
    "registrationId": event.registrationId,
    "blockNumber": event.blockNumber,
    "logIndex": event.logIndex,
    "transactionIndex": event.transactionIndex,
    "contractName": event.contractName,
    "eventName": event.eventName,
    "srcAddress": event.srcAddress,
    "params": event.params,
    "block": {
      "number": block.number,
      "timestamp": block.timestamp,
      "hash": block.hash,
      "parentHash": block.parentHash,
      "gasUsed": block.gasUsed->BigInt.toString,
      "miner": block.miner->Address.toString,
    },
    "transaction": {
      "hash": transaction.hash,
      "transactionIndex": transaction.transactionIndex,
      "from": transaction.from->Address.toString,
      "gas": transaction.gas->BigInt.toString,
      "gasUsed": transaction.gasUsed->BigInt.toString,
      "status": transaction.status,
    },
  }
}

let registerContractTests = (~name, ~factory: sourceFactory) => {
  describe(`RPC source public contract - ${name}`, () => {
    Async.it("pins enrichment, event order, request deduplication, and reorg hashes", async t => {
      let page = await MockRpcServer.withScenario(
        ~name=`${name}: successful enriched page`,
        ~calls=successfulCalls(),
        async mock => {
          let registration = makeRegistration()
          let source = makeSource(~factory, ~url=mock.url, ~registration)
          switch await RpcSourcePins.capture(() => source->invoke(~registration)) {
          | Ok(page) => page
          | Error(_) => JsError.throwWithMessage("Expected the pinned RPC page to succeed")
          }
        },
      )

      t.expect({
        "knownHeight": page.knownHeight,
        "fromBlockQueried": page.fromBlockQueried,
        "latestFetchedBlockNumber": page.latestFetchedBlockNumber,
        "latestFetchedBlockTimestamp": page.latestFetchedBlockTimestamp,
        "events": page.events->Array.map(eventSummary),
        "blockHashes": page.blockHashes,
        "requestCounts": page.requestCounts,
      }).toEqual({
        "knownHeight": 100,
        "fromBlockQueried": 100,
        "latestFetchedBlockNumber": 100,
        "latestFetchedBlockTimestamp": 100,
        "events": [
          {
            "registrationId": `${sighash}_1`,
            "blockNumber": 100,
            "logIndex": 2,
            "transactionIndex": 1,
            "contractName": "ERC20",
            "eventName": "EventWithoutFields",
            "srcAddress": normalizedContractAddress,
            "params": %raw(`{}`),
            "block": {
              "number": 100,
              "timestamp": 100,
              "hash": "0xb64",
              "parentHash": "0xb63",
              "gasUsed": "21000",
              "miner": normalizedMinerAddress,
            },
            "transaction": {
              "hash": transactionHash,
              "transactionIndex": 1,
              "from": normalizedFromAddress,
              "gas": "30000",
              "gasUsed": "21000",
              "status": 1,
            },
          },
          {
            "registrationId": `${sighash}_1`,
            "blockNumber": 100,
            "logIndex": 3,
            "transactionIndex": 1,
            "contractName": "ERC20",
            "eventName": "EventWithoutFields",
            "srcAddress": normalizedContractAddress,
            "params": %raw(`{}`),
            "block": {
              "number": 100,
              "timestamp": 100,
              "hash": "0xb64",
              "parentHash": "0xb63",
              "gasUsed": "21000",
              "miner": normalizedMinerAddress,
            },
            "transaction": {
              "hash": transactionHash,
              "transactionIndex": 1,
              "from": normalizedFromAddress,
              "gas": "30000",
              "gasUsed": "21000",
              "status": 1,
            },
          },
        ],
        "blockHashes": [
          {ReorgDetection.blockNumber: 100, blockHash: "0xb64"},
          {ReorgDetection.blockNumber: 99, blockHash: "0xb63"},
          {ReorgDetection.blockNumber: 99, blockHash: "0xb63"},
          {ReorgDetection.blockNumber: 98, blockHash: "0xb62"},
          {ReorgDetection.blockNumber: 100, blockHash: "0xb64"},
          {ReorgDetection.blockNumber: 100, blockHash: "0xb64"},
        ],
        "requestCounts": Dict.fromArray([
          ("eth_getLogs", 1),
          ("eth_getBlockByNumber", 2),
          ("eth_getTransactionByHash", 1),
          ("eth_getTransactionReceipt", 1),
        ]),
      })
    })

    Async.it("pins onReorg cache invalidation without resetting paging state", async t => {
      let requestCounts = await MockRpcServer.withScenario(
        ~name=`${name}: onReorg cache invalidation`,
        ~calls=successfulCalls(~times=2, ~logs=[log(~logIndex="0x2")]),
        async mock => {
          let registration = makeRegistration()
          let source = makeSource(~factory, ~url=mock.url, ~registration)
          let _ = await source->invoke(~registration)
          let onReorg = source.onReorg->Option.getOrThrow(
            ~message="RPC source must expose onReorg for cache invalidation",
          )
          onReorg(~rollbackTargetBlock=99)
          let _ = await source->invoke(~registration)
          mock.transcript()
          ->Array.reduce(Dict.make(), (counts, entry) => {
            let method = entry.request.method
            counts->Dict.set(method, counts->Dict.get(method)->Option.getOr(0) + 1)
            counts
          })
        },
      )

      t.expect(requestCounts).toEqual(Dict.fromArray([
        ("eth_getLogs", 2),
        ("eth_getBlockByNumber", 4),
        ("eth_getTransactionByHash", 2),
        ("eth_getTransactionReceipt", 2),
      ]))
    })

    Async.it("pins missing receipt data as a retryable source error", async t => {
      let error = await MockRpcServer.withScenario(
        ~name=`${name}: missing receipt`,
        ~calls=[
          MockRpcServer.expectCall(
            ~method="eth_getLogs",
            ~params=getLogsParams(),
            ~reply=RpcResult(JSON.Array([log(~logIndex="0x2")])),
          ),
          MockRpcServer.expectCall(
            ~method="eth_getBlockByNumber",
            ~params=blockParams("0x63"),
            ~reply=RpcResult(block99),
          ),
          MockRpcServer.expectCall(
            ~method="eth_getBlockByNumber",
            ~params=blockParams("0x64"),
            ~reply=RpcResult(block100),
          ),
          MockRpcServer.expectCall(
            ~method="eth_getTransactionReceipt",
            ~params=JSON.Array([JSON.String(transactionHash)]),
            ~reply=RpcResult(JSON.Null),
          ),
        ],
        async mock => {
          let registration = makeRegistration(~receiptOnly=true)
          let source = makeSource(~factory, ~url=mock.url, ~registration)
          switch await RpcSourcePins.capture(() => source->invoke(~registration, ~retry=2)) {
          | Error(error) => error
          | Ok(_) => JsError.throwWithMessage("Expected missing receipt data to be retryable")
          }
        },
      )

      t.expect(error).toEqual(
        RpcSourcePins.FailedGettingItems({
          attemptedToBlock: 100,
          providerMessage: None,
          retry: Backoff({
            message: `Transaction receipt not found for hash: ${transactionHash}. The RPC provider might be load-balanced between nodes that drift independently slightly from the head. Indexing should continue correctly after retrying the query in 1000ms.`,
            backoffMillis: 1_000,
          }),
        }),
      )
    })

    Async.it("pins consecutive response-too-large interval shrinking", async t => {
      let defaultSyncConfig = EvmChain.getSyncConfig({})
      let errors = await MockRpcServer.withScenario(
        ~name=`${name}: density interval shrink`,
        ~calls=[
          MockRpcServer.expectCall(
            ~label="initial interval",
            ~method="eth_getLogs",
            ~params=JSON.parseOrThrow(
              `[{"fromBlock":"0x0","toBlock":"0x270f","topics":[["${sighash}"]],"address":["${normalizedContractAddress}"]}]`,
            ),
            ~reply=RpcError({code: -32005, message: "More than 50000 logs returned"}),
          ),
          MockRpcServer.expectCall(
            ~label="shrunk interval",
            ~method="eth_getLogs",
            ~params=JSON.parseOrThrow(
              `[{"fromBlock":"0x0","toBlock":"0x1f3f","topics":[["${sighash}"]],"address":["${normalizedContractAddress}"]}]`,
            ),
            ~reply=RpcError({code: -32005, message: "More than 50000 logs returned"}),
          ),
        ],
        async mock => {
          let registration = makeRegistration()
          let options: RpcSource.options = {
            url: mock.url,
            chain,
            onEventRegistrations: [registration],
            sourceFor: Sync,
            syncConfig: defaultSyncConfig,
            lowercaseAddresses: true,
          }
          let source = factory(options)
          let addressesByContractName = Dict.fromArray([
            (registration.eventConfig.contractName, [address]),
          ])
          let call = () =>
            RpcSourcePins.capture(() =>
              source.getItemsOrThrow(
                ~fromBlock=0,
                ~toBlock=Some(1_000_000),
                ~addressesByContractName,
                ~contractNameByAddress=FetchState.deriveContractNameByAddress(
                  addressesByContractName,
                ),
                ~knownHeight=1_000_000,
                ~partitionId="pin-partition",
                ~selection={
                  dependsOnAddresses: true,
                  onEventRegistrations: [(registration :> Internal.onEventRegistration)],
                },
                ~itemsTarget=Some(5_000),
                ~retry=0,
                ~logger=Logging.createChild(~params={"test": "RPC interval pin"}),
              )
            )
          (await call(), await call())
        },
      )

      t.expect(errors).toEqual((
        Error(
          RpcSourcePins.FailedGettingItems({
            attemptedToBlock: 9_999,
            providerMessage: Some("More than 50000 logs returned"),
            retry: SuggestedToBlock(7_999),
          }),
        ),
        Error(
          RpcSourcePins.FailedGettingItems({
            attemptedToBlock: 7_999,
            providerMessage: Some("More than 50000 logs returned"),
            retry: SuggestedToBlock(6_399),
          }),
        ),
      ))
    })

    Async.it("pins OR-filter fan-out and duplicate-log suppression", async t => {
      let filter1 =
        "0x0000000000000000000000000000000000000000000000000000000000000001"
      let filter2 =
        "0x0000000000000000000000000000000000000000000000000000000000000002"
      // Two indexed params so the log can carry topic1/topic2 the branches
      // filter on and decode cleanly (derived topicCount 3).
      let registration = makeRoutingRegistration(
        ~paramsMetadata=[
          {name: "a", abiType: "uint256", indexed: true},
          {name: "b", abiType: "uint256", indexed: true},
        ],
        ~eventFilters=[
          {
            Internal.topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
            topic1: Values([filter1->EvmTypes.Hex.fromStringUnsafe]),
            topic2: Values([]),
            topic3: Values([]),
          },
          {
            Internal.topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
            topic1: Values([]),
            topic2: Values([filter2->EvmTypes.Hex.fromStringUnsafe]),
            topic3: Values([]),
          },
        ],
      )
      // Carries both filtered topics, so a real provider returns it for either
      // branch's server-side filter; routing re-checks the registration's
      // topic filters against these values and dedups to one item.
      let orFanOutLog = JSON.parseOrThrow(
        `{"address":"${contractAddress}","topics":["${sighash}","${filter1}","${filter2}"],"data":"0x","blockNumber":"0x64","transactionHash":"${transactionHash}","transactionIndex":"0x1","blockHash":"0xb64","logIndex":"0x2","removed":false}`,
      )
      let page = await MockRpcServer.withScenario(
        ~name=`${name}: OR fan-out and dedup`,
        ~calls=[
          MockRpcServer.expectCall(
            ~label="topic1 branch",
            ~method="eth_getLogs",
            ~params=JSON.parseOrThrow(
              `[{"fromBlock":"0x64","toBlock":"0x64","topics":[["${sighash}"],["${filter1}"]],"address":["${normalizedContractAddress}"]}]`,
            ),
            ~reply=RpcResult(JSON.Array([orFanOutLog])),
          ),
          MockRpcServer.expectCall(
            ~label="topic2 branch",
            ~method="eth_getLogs",
            ~params=JSON.parseOrThrow(
              `[{"fromBlock":"0x64","toBlock":"0x64","topics":[["${sighash}"],null,["${filter2}"]],"address":["${normalizedContractAddress}"]}]`,
            ),
            ~reply=RpcResult(JSON.Array([orFanOutLog])),
          ),
          MockRpcServer.expectCall(
            ~method="eth_getBlockByNumber",
            ~params=blockParams("0x63"),
            ~reply=RpcResult(block99),
          ),
          MockRpcServer.expectCall(
            ~method="eth_getBlockByNumber",
            ~params=blockParams("0x64"),
            ~reply=RpcResult(block100),
          ),
        ],
        async mock => {
          let source = makeSource(~factory, ~url=mock.url, ~registration)
          switch await RpcSourcePins.capture(() => source->invoke(~registration)) {
          | Ok(page) => page
          | Error(_) => JsError.throwWithMessage("Expected the OR-filter page to succeed")
          }
        },
      )

      t.expect({
        "eventLogIndexes": page.events->Array.map(event => event.logIndex),
        "requestCounts": page.requestCounts,
      }).toEqual({
        "eventLogIndexes": [2],
        "requestCounts": Dict.fromArray([
          ("eth_getLogs", 2),
          ("eth_getBlockByNumber", 2),
        ]),
      })
    })

    Async.it("pins skip-all filters advancing without an eth_getLogs request", async t => {
      let registration = makeRoutingRegistration(~isWildcard=true, ~eventFilters=[])
      let page = await MockRpcServer.withScenario(
        ~name=`${name}: skip-all filter`,
        ~calls=[
          MockRpcServer.expectCall(
            ~method="eth_getBlockByNumber",
            ~params=blockParams("0x63"),
            ~reply=RpcResult(block99),
          ),
          MockRpcServer.expectCall(
            ~method="eth_getBlockByNumber",
            ~params=blockParams("0x64"),
            ~reply=RpcResult(block100),
          ),
        ],
        async mock => {
          let source = makeSource(~factory, ~url=mock.url, ~registration)
          switch await RpcSourcePins.capture(() =>
            source.getItemsOrThrow(
              ~fromBlock=100,
              ~toBlock=Some(100),
              ~addressesByContractName=Dict.make(),
              ~contractNameByAddress=Dict.make(),
              ~knownHeight=100,
              ~partitionId="skip-all",
              ~selection={
                dependsOnAddresses: false,
                onEventRegistrations: [(registration :> Internal.onEventRegistration)],
              },
              ~itemsTarget=Some(5_000),
              ~retry=0,
              ~logger=Logging.createChild(~params={"test": "RPC skip-all pin"}),
            )
          ) {
          | Ok(page) => page
          | Error(_) => JsError.throwWithMessage("Expected the skip-all page to advance")
          }
        },
      )

      t.expect({
        "events": page.events->Array.length,
        "latestFetchedBlockNumber": page.latestFetchedBlockNumber,
        "requestCounts": page.requestCounts,
      }).toEqual({
        "events": 0,
        "latestFetchedBlockNumber": 100,
        "requestCounts": Dict.fromArray([("eth_getBlockByNumber", 2)]),
      })
    })

    Async.it("pins each contract filter to only that contract's addresses", async t => {
      let addressAString = "0x00000000000000000000000000000000000000a1"
      let addressBString = "0x00000000000000000000000000000000000000b1"
      let addressA = addressAString->Address.unsafeFromString
      let addressB = addressBString->Address.unsafeFromString
      let filterA =
        "0x000000000000000000000000000000000000000000000000000000000000000a"
      let filterB =
        "0x000000000000000000000000000000000000000000000000000000000000000b"
      let selectionFor = filter => [
        {
          Internal.topic0: [sighash->EvmTypes.Hex.fromStringUnsafe],
          topic1: Values([filter->EvmTypes.Hex.fromStringUnsafe]),
          topic2: Values([]),
          topic3: Values([]),
        },
      ]
      // One indexed param so each contract's topic1-filtered log decodes.
      let addressParam: array<Internal.paramMeta> = [
        {name: "who", abiType: "address", indexed: true},
      ]
      let eventA = makeRoutingRegistration(
        ~contractName="ContractA",
        ~paramsMetadata=addressParam,
        ~eventFilters=selectionFor(filterA),
      )
      let eventB = makeRoutingRegistration(
        ~index=1,
        ~contractName="ContractB",
        ~paramsMetadata=addressParam,
        ~eventFilters=selectionFor(filterB),
      )
      // A real provider's log for a topic1-filtered request carries that
      // contract's filtered topic1 value; routing re-checks it per registration.
      let logFor = (~address, ~topic1, ~logIndex) =>
        JSON.parseOrThrow(
          `{"address":"${address}","topics":["${sighash}","${topic1}"],"data":"0x","blockNumber":"0x64","transactionHash":"${transactionHash}","transactionIndex":"0x1","blockHash":"0xb64","logIndex":"${logIndex}","removed":false}`,
        )

      let page = await MockRpcServer.withScenario(
        ~name=`${name}: contract address scoping`,
        ~calls=[
          MockRpcServer.expectCall(
            ~label="ContractA logs",
            ~method="eth_getLogs",
            ~params=JSON.parseOrThrow(
              `[{"fromBlock":"0x64","toBlock":"0x64","topics":[["${sighash}"],["${filterA}"]],"address":["${addressAString}"]}]`,
            ),
            ~reply=RpcResult(JSON.Array([logFor(~address=addressAString, ~topic1=filterA, ~logIndex="0x2")])),
          ),
          MockRpcServer.expectCall(
            ~label="ContractB logs",
            ~method="eth_getLogs",
            ~params=JSON.parseOrThrow(
              `[{"fromBlock":"0x64","toBlock":"0x64","topics":[["${sighash}"],["${filterB}"]],"address":["${addressBString}"]}]`,
            ),
            ~reply=RpcResult(JSON.Array([logFor(~address=addressBString, ~topic1=filterB, ~logIndex="0x3")])),
          ),
          MockRpcServer.expectCall(
            ~method="eth_getBlockByNumber",
            ~params=blockParams("0x63"),
            ~reply=RpcResult(block99),
          ),
          MockRpcServer.expectCall(
            ~method="eth_getBlockByNumber",
            ~params=blockParams("0x64"),
            ~reply=RpcResult(block100),
          ),
        ],
        async mock => {
          let options: RpcSource.options = {
            url: mock.url,
            chain,
            onEventRegistrations: [eventA, eventB],
            sourceFor: Sync,
            syncConfig,
            lowercaseAddresses: true,
          }
          let source = factory(options)
          let addressesByContractName = Dict.fromArray([
            ("ContractA", [addressA]),
            ("ContractB", [addressB]),
          ])
          switch await RpcSourcePins.capture(() =>
            source.getItemsOrThrow(
              ~fromBlock=100,
              ~toBlock=Some(100),
              ~addressesByContractName,
              ~contractNameByAddress=FetchState.deriveContractNameByAddress(
                addressesByContractName,
              ),
              ~knownHeight=100,
              ~partitionId="contract-scope",
              ~selection={
                dependsOnAddresses: true,
                onEventRegistrations: [
                  (eventA :> Internal.onEventRegistration),
                  (eventB :> Internal.onEventRegistration),
                ],
              },
              ~itemsTarget=Some(5_000),
              ~retry=0,
              ~logger=Logging.createChild(~params={"test": "RPC contract scoping pin"}),
            )
          ) {
          | Ok(page) => page
          | Error(_) => JsError.throwWithMessage("Expected contract-scoped queries to succeed")
          }
        },
      )

      t.expect(page.events->Array.map(event => (
        event.contractName,
        event.srcAddress,
        event.logIndex,
      ))).toEqual([
        ("ContractA", addressAString, 2),
        ("ContractB", addressBString, 3),
      ])
    })
  })
}

registerContractTests(~name="current hybrid implementation", ~factory=RpcSource.make)
