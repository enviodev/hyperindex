// Legacy surface for the tests that still run against the generated project
// config. The machinery lives in `envio-tests` (MockSource / MockStorage /
// IndexerRunner); this layer only re-attaches the generated `Indexer` types and
// the config overrides those tests take as arguments. It goes away with the
// last test migrated to `Scenario`.
type chainId = Indexer.chainId

// The generated project config. Cheap: Config.load() memoizes the pure parse.
let config = Config.load()

let entityConfigByName = IndexerRunner.entityConfigByName

let entityConfig = (name: string): Internal.entityConfig => config->entityConfigByName(name)

let evmBlockHash = MockSource.evmBlockHash

// The store requires a persistence/config even when the cycle never runs; reuse one.
// Lazy so importing the helper doesn't open a pg client for tests that never use it.
// Its schema is never created — a query through this persistence means a test is
// wired wrong, and pointing it at a real schema would hide that.
let defaultPersistenceRef = ref(None)
let defaultPersistence = () =>
  switch defaultPersistenceRef.contents {
  | Some(persistence) => persistence
  | None =>
    let config = Config.load()
    let persistence = PgStorage.makePersistenceFromConfig(
      ~config,
      ~storage=PgStorage.makeStorageFromEnv(
        ~config,
        ~sql=PgStorage.makeClient(),
        ~pgSchema=TestPgSchema.make(),
        ~isHasuraEnabled=false,
      ),
    )
    defaultPersistenceRef := Some(persistence)
    persistence
  }

module Gate = MockSource.Gate

module InMemoryStore = {
  let setEntity = (
    indexerState,
    ~entityConfig: Internal.entityConfig,
    ~scope=Internal.CrossChain,
    entity,
  ) => {
    let inMemTable = indexerState->InMemoryStore.getInMemTable(~entityConfig, ~scope)
    let entity = entity->(Utils.magic: 'a => Internal.entity)
    inMemTable->InMemoryTable.Entity.set(
      ~committedCheckpointId=indexerState->IndexerState.committedCheckpointId,
      Set({
        entityId: (entity: Internal.entity).id->EntityId.unsafeOfString,
        checkpointId: 0n,
        entity,
      }),
    )
  }

  let make = (~config=?, ~entities=[]) => {
    let config = switch config {
    | Some(config) => config
    | None => Config.load()
    }
    let indexerState = IndexerState.make(
      ~config,
      ~persistence=defaultPersistence(),
      // A trivial chain state map for store-only tests that never run the loop.
      ~chainStates=Dict.make(),
      ~isInReorgThreshold=false,
      ~isRealtime=false,
      // The cycle never runs here, so a write only means a test is wired wrong.
      ~onError=errHandler => errHandler->ErrorHandling.raiseExn,
    )
    entities->Array.forEach(((entityConfig, items)) => {
      items->Array.forEach(entity => {
        indexerState->setEntity(~entityConfig, entity)
      })
    })
    indexerState
  }
}

module Storage = {
  type method = MockStorage.method
  type t = MockStorage.t

  let make = MockStorage.make

  let toPersistence = (storageMock: t, ~config=?) =>
    storageMock->MockStorage.toPersistence(~config=config->Option.getOr(Config.load()))
}

// Aliases to access the generated Indexer module after the local `module Indexer` shadows it
type eventLog<'a> = Internal.genericEvent<'a, Indexer.Block.t, Indexer.Transaction.t>
type handlerContext = Indexer.handlerContext
type contractRegister<'a> = Internal.genericContractRegister<
  Internal.genericContractRegisterArgs<
    Internal.genericEvent<'a, Indexer.Block.t, Indexer.Transaction.t>,
    Indexer.contractRegisterContext,
  >,
>
module Transaction = Indexer.Transaction

module Indexer = {
  type metric = IndexerRunner.metric
  type t = IndexerRunner.t

  type chainConfig = {
    chain: chainId,
    sourceConfig: Config.sourceConfig,
    startBlock?: int,
    endBlock?: int,
    maxReorgDepth?: int,
    blockLag?: int,
  }

  let run = async (
    ~chains: array<chainConfig>,
    ~config as customConfig: option<Config.t>=?,
    ~saveFullHistory=false,
    ~enableRawEvents=false,
    ~batchSize=?,
    ~maxAddrInPartition=?,
    ~clientFilterAddressThreshold=?,
    ~shouldRollbackOnReorg=true,
    ~reducedPollingInterval=?,
    ~targetBufferSize=?,
    ~reorgThresholdReadyTolerance=0,
    ~onError=?,
    ~onExit=?,
    ~mapStorage: Persistence.storage => Persistence.storage=storage => storage,
    body: IndexerRunner.t => promise<unit>,
  ) => {
    // The full (un-narrowed) config. Handlers register against this so every
    // chain resolves once; `finishRegistration` then narrows to the per-test
    // `config` below.
    let baseConfig = switch customConfig {
    | Some(config) => config
    | None => Config.load()
    }

    // Build the final per-test config (chain overrides, enableRawEvents, ...).
    let config = {
      let chainMap =
        chains
        ->Array.map(chainConfig => {
          let chainId = (chainConfig.chain :> int)->ChainId.fromInt
          let originalChainConfig = baseConfig.chainMap->ChainMap.get(chainId)
          (
            chainId,
            {
              ...originalChainConfig,
              sourceConfig: chainConfig.sourceConfig,
              startBlock: chainConfig.startBlock->Option.getOr(originalChainConfig.startBlock),
              endBlock: ?switch chainConfig.endBlock {
              | Some(_) as endBlock => endBlock
              | None => originalChainConfig.endBlock
              },
              maxReorgDepth: chainConfig.maxReorgDepth->Option.getOr(
                originalChainConfig.maxReorgDepth,
              ),
              blockLag: chainConfig.blockLag->Option.getOr(originalChainConfig.blockLag),
            },
          )
        })
        ->ChainMap.fromArrayUnsafe

      {
        ...baseConfig,
        shouldRollbackOnReorg,
        shouldSaveFullHistory: saveFullHistory,
        enableRawEvents,
        chainMap,
        batchSize: batchSize->Option.getOr(baseConfig.batchSize),
        maxAddrInPartition: maxAddrInPartition->Option.getOr(baseConfig.maxAddrInPartition),
        clientFilterAddressThreshold: clientFilterAddressThreshold->Option.getOr(
          baseConfig.clientFilterAddressThreshold,
        ),
        reorgThresholdReadyTolerance,
      }
    }

    await IndexerRunner.run(
      ~config,
      // These tests read the generated project's Postgres schema throughout.
      ~backend=#postgres,
      ~resolveRegistrations=async () => {
        // Register handlers once against the full chain set (idempotent +
        // import-cached, so a restart reuses), then narrow to this run's chains.
        switch customConfig {
        | None =>
          let _ = await HandlerLoader.registerAllHandlers(~config=baseConfig)
        | Some(_) =>
          // A supplied config has no handler files on disk; register inline
          // handlers (if any) through the same public registry lifecycle.
          HandlerRegister.startRegistration(~config=baseConfig)
        }
        HandlerRegister.finishRegistration(~config)
      },
      ~reducedPollingInterval?,
      ~targetBufferSize?,
      ~onError?,
      ~onExit?,
      ~mapStorage,
      body,
    )
  }
}

module Source = {
  module CallPayload = MockSource.CallPayload

  type method = MockSource.method

  type itemMock = {
    blockNumber: int,
    logIndex: int,
    handler?: Internal.genericHandlerArgs<eventLog<unknown>, handlerContext> => promise<unit>,
    contractRegister?: contractRegister<unit>,
  }

  type getItemsOrThrowCall = {
    payload: {"fromBlock": int, "toBlock": option<int>, "retry": int, "p": string},
    resolve: (
      array<itemMock>,
      ~latestFetchedBlockNumber: int=?,
      ~latestFetchedBlockHash: string=?,
      ~knownHeight: int=?,
      ~prevRangeLastBlock: ReorgDetection.blockData=?,
    ) => unit,
    reject: 'exn. 'exn => unit,
  }

  type t = {
    source: Source.t,
    getHeightOrThrowCalls: array<bool>,
    resolveGetHeightOrThrow: int => unit,
    rejectGetHeightOrThrow: 'exn. 'exn => unit,
    getItemsOrThrowCalls: array<getItemsOrThrowCall>,
    reorgCallCount: unit => int,
    resolveGetItemsOrThrow: (
      array<itemMock>,
      ~resolveAt: [#first | #all | #last]=?,
      ~latestFetchedBlockNumber: int=?,
      ~latestFetchedBlockHash: string=?,
      ~knownHeight: int=?,
      ~prevRangeLastBlock: ReorgDetection.blockData=?,
    ) => unit,
    getBlockHashesCalls: array<array<int>>,
    resolveGetBlockHashes: array<BlockStore.inputBlock> => unit,
    heightSubscriptionCalls: array<bool>,
    triggerHeightSubscription: int => unit,
    unsubscribeHeightSubscription: unit => unit,
  }

  // The two `t`s differ only in how the item callbacks type their context: the
  // generated one here, an opaque `Internal.handlerContext` in the core.
  let make = (
    methods: array<method>,
    ~chainId=#1: chainId,
    ~sourceFor=Source.Sync,
    ~pollingInterval=1000,
  ) =>
    MockSource.make(methods, ~chainId=(chainId :> int), ~sourceFor, ~pollingInterval)->(
      Utils.magic: MockSource.t => t
    )
}

module Helper = {
  let waitItemsQuery = (sourceMock: Source.t) =>
    sourceMock->(Utils.magic: Source.t => MockSource.t)->MockSource.waitItemsQuery

  let initialEnterReorgThreshold = async (
    ~t: Vitest.testContext,
    ~indexerMock: Indexer.t,
    ~sourceMock: Source.t,
  ) => {
    t.expect(
      sourceMock.getHeightOrThrowCalls->Array.length,
      ~message="should have called getHeightOrThrow to get initial height",
    ).toEqual(1)
    sourceMock.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    t.expect(
      sourceMock.getItemsOrThrowCalls->Array.map(call => call.payload),
      ~message="Should request items until reorg threshold",
    ).toEqual(// fromBlock 1 since it's in the config.yaml start_block is 1
    [{"fromBlock": 1, "toBlock": Some(100), "retry": 0, "p": "0"}])
    sourceMock.resolveGetItemsOrThrow([])
    await indexerMock.getBatchWritePromise()
  }
}

let mockRawEventRow: InternalTable.RawEvents.t = {
  chain_id: 1->ChainId.fromInt,
  event_id: 1234567890n,
  contract_name: "NftFactory",
  event_name: "SimpleNftCreated",
  block_number: 1000,
  log_index: 10,
  transaction_fields: %raw(`{"transactionIndex": 20, "hash": "0x1234567890abcdef"}`),
  src_address: "0x0123456789abcdef0123456789abcdef0123456"->Utils.magic,
  block_hash: "0x9876543210fedcba9876543210fedcba987654321",
  block_timestamp: 1620720000,
  block_fields: %raw(`{}`),
  params: {
    "foo": "bar",
    "baz": 42,
  }->Utils.magic,
}

let eventId = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f_1"

let evmOnEventRegistration = (
  ~id=eventId,
  ~contractName="ERC20",
  ~blockFieldNames: array<Internal.evmBlockField>=[],
  ~transactionFieldNames: array<Internal.evmTransactionField>=[],
  ~isWildcard=false,
  ~dependsOnAddresses=?,
  ~filterByAddresses=false,
  ~startBlock: option<int>=?,
  ~eventFilters: option<array<Internal.resolvedTopicSelection>>=?,
  // Override the event's ABI when a test needs indexed params (so its logs
  // carry the topics its `where` filters on). Defaults to a no-param,
  // single-topic event. `topicCount` is derived from the indexed params the
  // same way production's `EventConfigBuilder.buildEvmEventConfig` does, so the
  // two can't drift.
  ~paramsMetadata: array<Internal.paramMeta>=[],
  ~topicCount=paramsMetadata->Array.reduce(1, (acc, p) => p.indexed ? acc + 1 : acc),
): Internal.evmOnEventRegistration => {
  let eventConfig: Internal.evmEventConfig = {
    id,
    contractName,
    name: "EventWithoutFields",
    paramsRawEventSchema: EventConfigBuilder.buildParamsSchema(paramsMetadata),
    simulateParamsSchema: EventConfigBuilder.buildSimulateParamsSchema(paramsMetadata),
    fieldSelection: Internal.makeFieldSelection(
      ~blockFields=Utils.Set.fromArray(blockFieldNames)->(
        Utils.magic: Utils.Set.t<Internal.evmBlockField> => Utils.Set.t<string>
      ),
      ~transactionFields=Utils.Set.fromArray(transactionFieldNames)->(
        Utils.magic: Utils.Set.t<Internal.evmTransactionField> => Utils.Set.t<string>
      ),
      ~blockMaskFn=Evm.eventBlockFieldMask,
      ~transactionMaskFn=Evm.eventTransactionFieldMask,
    ),
    sighash: id,
    topicCount,
    paramsMetadata,
  }
  {
    index: -1,
    eventConfig: (eventConfig :> Internal.eventConfig),
    isWildcard,
    filterByAddresses,
    dependsOnAddresses: filterByAddresses || dependsOnAddresses->Option.getOr(!isWildcard),
    addressFilterParamGroups: [],
    startBlock,
    handler: None,
    contractRegister: None,
    fieldSelection: eventConfig.fieldSelection,
    resolvedWhere: {
      topicSelections: switch eventFilters {
      | Some(topicSelections) => topicSelections
      | None => [
          {
            topic0: [
              // This is a sighash in the original code
              id->EvmTypes.Hex.fromStringUnsafe,
            ],
            topic1: switch dependsOnAddresses {
            | Some(true) => ContractAddresses({contractName: contractName})
            | _ => Values([])
            },
            topic2: Values([]),
            topic3: Values([]),
          },
        ]
      },
      startBlock: None,
    },
  }
}
