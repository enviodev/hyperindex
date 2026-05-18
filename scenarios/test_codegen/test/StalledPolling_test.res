open Vitest

// Reproduction for a loophole in the polling-stall logic.
//
// `GlobalState.checkAndFetchForChain` enables `reducedPolling` only when
// `ChainFetcher.isReady` is true (i.e. `timestampCaughtUpToHeadOrEndblock`
// has been set). That flag, however, only flips after a batch has been
// processed for the chain. A chain can have its buffer fetched all the way
// to the head while not a single event has been processed yet — e.g. in
// multichain Ordered mode where another chain's older events are blocking
// processing. In that state there's nothing useful to fetch for this chain,
// but it keeps polling the source at the normal rate.

let baseConfig = Config.loadWithoutRegistrations()
let baseChain = baseConfig.defaultChain->Option.getUnsafe

let mockEventConfig = (MockIndexer.evmEventConfig(
  ~id="0",
  ~contractName="Gravatar",
  ~isWildcard=true,
) :> Internal.eventConfig)

let makeChainConfig = (~id) => {
  ...baseChain,
  id,
  name: `chain${id->Int.toString}`,
}

let makeFetchState = (~knownHeight, ~latestFetchedBlockNumber) => {
  let initial = FetchState.make(
    ~maxAddrInPartition=Env.maxAddrInPartition,
    ~endBlock=None,
    ~eventConfigs=[mockEventConfig],
    ~addresses=[],
    ~startBlock=0,
    ~targetBufferSize=5000,
    ~chainId=1,
    ~knownHeight,
  )

  let query: FetchState.query = {
    partitionId: "0",
    fromBlock: 0,
    toBlock: None,
    isChunk: false,
    selection: {dependsOnAddresses: false, eventConfigs: [mockEventConfig]},
    addressesByContractName: Dict.make(),
    indexingAddresses: initial.indexingAddresses,
  }
  initial->FetchState.startFetchingQueries(~queries=[query])
  initial->FetchState.handleQueryResult(
    ~query,
    ~latestFetchedBlock={
      blockNumber: latestFetchedBlockNumber,
      blockTimestamp: latestFetchedBlockNumber * 15,
    },
    ~newItems=[],
  )
}

let makeChainFetcher = (~chainConfig: Config.chain, ~fetchState) => {
  let mockSource = MockIndexer.Source.make(
    [#getHeightOrThrow],
    ~chain=chainConfig.id->(Utils.magic: int => MockIndexer.chainId),
  )
  let sourceManager = SourceManager.make(
    ~sources=[mockSource.source],
    ~maxPartitionConcurrency=Env.maxPartitionConcurrency,
    ~isRealtime=false,
  )
  let chainFetcher: ChainFetcher.t = {
    timestampCaughtUpToHeadOrEndblock: None,
    committedProgressBlockNumber: -1,
    numEventsProcessed: 0.,
    fetchState,
    logger: Logging.getLogger(),
    sourceManager,
    chainConfig,
    reorgDetection: ReorgDetection.make(
      ~chainReorgCheckpoints=[],
      ~maxReorgDepth=200,
      ~shouldRollbackOnReorg=false,
    ),
    safeCheckpointTracking: None,
    isProgressAtHead: false,
  }
  (chainFetcher, mockSource)
}

let makeMockState = () => {
  let chainAConfig = makeChainConfig(~id=1)
  let chainBConfig = makeChainConfig(~id=2)
  let chainA = ChainMap.Chain.makeUnsafe(~chainId=1)
  let chainB = ChainMap.Chain.makeUnsafe(~chainId=2)

  // Chain A: buffer fully fetched to the head, but no batch processed yet
  // (so timestampCaughtUpToHeadOrEndblock is still None — `isReady` is false).
  let (cfA, mockSourceA) = makeChainFetcher(
    ~chainConfig=chainAConfig,
    ~fetchState=makeFetchState(~knownHeight=100, ~latestFetchedBlockNumber=100),
  )
  // Chain B: still backfilling — buffer behind the head.
  let (cfB, _mockSourceB) = makeChainFetcher(
    ~chainConfig=chainBConfig,
    ~fetchState=makeFetchState(~knownHeight=100, ~latestFetchedBlockNumber=50),
  )

  let chainManager: ChainManager.t = {
    committedCheckpointId: 0n,
    chainFetchers: ChainMap.fromArrayUnsafe([(chainA, cfA), (chainB, cfB)]),
    multichain: Ordered,
    isInReorgThreshold: false,
    // Not all chains have reached head yet → backfill phase.
    isRealtime: false,
  }

  let ctx: Ctx.t = {
    registrations: {onBlockByChainId: Dict.make()},
    // shouldRollbackOnReorg=false so the second branch of the reducedPolling
    // formula can never fire — isolates the loophole to the `isReady` branch.
    config: {...baseConfig, shouldRollbackOnReorg: false},
    persistence: %raw(`{}`),
  }
  let state = GlobalState.make(~ctx, ~chainManager)
  (state, chainA, mockSourceA)
}

describe("Polling-stall loophole", () => {
  Async.it_fails(
    "Stalls polling when chain buffer is at the head but no batch has been processed yet",
    async t => {
      let (state, chainA, _) = makeMockState()

      let recordedReducedPolling = ref(None)
      let waitForNewBlock = (
        _sourceManager,
        ~knownHeight as _,
        ~isRealtime as _,
        ~reducedPolling,
      ) => {
        recordedReducedPolling := Some(reducedPolling)
        Promise.make((_resolve, _reject) => ())
      }

      let executeQuery = (_sourceManager, ~query as _, ~knownHeight as _, ~isRealtime as _) =>
        JsError.throwWithMessage(
          "executeQuery should not be called when the buffer is already at the head",
        )

      let _ =
        GlobalState.checkAndFetchForChain(
          ~waitForNewBlock,
          ~executeQuery,
          ~state,
          ~dispatchAction=_ => (),
        )(chainA)

      await Utils.delay(0)
      await Utils.delay(0)

      // Sanity: verify we reached the WaitingForNewBlock branch at all.
      t.expect(
        recordedReducedPolling.contents->Option.isSome,
        ~message="waitForNewBlock should have been called (FetchState should be in WaitingForNewBlock state because the buffer is at the head)",
      ).toBe(true)

      t.expect(
        recordedReducedPolling.contents,
        ~message="Chain A has nothing useful to fetch (buffer at head while Chain B backfills), so reducedPolling should be true",
      ).toEqual(Some(true))
    },
  )
})
