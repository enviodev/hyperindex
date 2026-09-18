let chainId = 1->ChainId.fromInt
let chainConfig = {
  ...TestConfig.default.chainMap->ChainMap.values->Utils.Array.firstUnsafe,
  id: chainId,
}

let registrationsByChainId: HandlerRegister.registrationsByChainId = {
  let d = Dict.make()
  d->Dict.set(
    chainId->ChainId.toString,
    (
      {
        onEventRegistrations: [],
        // FetchState needs something to index; an onBlock registration is the
        // cheapest thing that doesn't require real event configs.
        onBlockRegistrations: [
          {
            Internal.index: 0,
            name: "test-chain-metrics",
            chainId,
            startBlock: None,
            endBlock: None,
            interval: 1,
            handler: "mock onBlock handler"->(
              Utils.magic: string => Internal.onBlockArgs => promise<unit>
            ),
          },
        ],
      }: HandlerRegister.chainRegistrations
    ),
  )
  d
}

let caughtUpAt = Date.fromTime(1700000000000.)

let make = (
  ~endBlock=None,
  ~progressBlockNumber,
  ~firstEventBlockNumber,
  ~timestampCaughtUpToHeadOrEndblock=None,
  ~sourceBlockNumber=1000,
): Metrics.chainMetrics =>
  ChainState.makeFromDbState(
    chainConfig,
    ~resumedChainState={
      id: chainId,
      startBlock: 100,
      endBlock,
      maxReorgDepth: 200,
      progressBlockNumber,
      progressBlockTime: None,
      numEventsProcessed: 7.,
      firstEventBlockNumber,
      timestampCaughtUpToHeadOrEndblock,
      addressRows: AddressRows.emptySeedRows(),
      sourceBlockNumber,
    },
    ~reorgCheckpoints=[],
    ~isInReorgThreshold=false,
    ~isRealtime=false,
    ~config=TestConfig.default,
    ~contractMapping=TestConfig.default.contractMapping,
    ~registrationsByChainId,
  )->ChainState.toMetrics

// The snapshot a run reports when nothing has happened yet. Tests spread this
// and name only the chains they assert on.
let emptySnapshot: Metrics.t = {
  startTime: Date.fromTime(0.),
  metricTime: Date.fromTime(0.),
  elapsedSeconds: 0.,
  targetBufferSize: 0,
  isInReorgThreshold: false,
  rollbackEnabled: false,
  maxBatchSize: 0,
  preloadSeconds: 0.,
  processingSeconds: 0.,
  processingStalledOnFetchSeconds: 0.,
  processingStalledOnStorageWriteSeconds: 0.,
  rollbackSeconds: 0.,
  rollbackCount: 0,
  rollbackEventsCount: 0.,
  chains: [],
  handlers: [],
  effects: [],
  storageLoads: [],
  storageWrites: [],
  historyPrunes: [],
  sourceRequests: [],
  sourceHeights: [],
  sourceHeightStreams: [],
}
