// Per-chain runtime state. `t` is opaque: other modules read it through the
// accessors and change it only through the mutators exposed here.

type t

let configAddresses: Config.chain => array<Internal.indexingAddress>

let make: (
  ~chainConfig: Config.chain,
  ~fetchState: FetchState.t,
  ~onEventRegistrations: array<Internal.onEventRegistration>=?,
  ~indexingAddresses: IndexingAddresses.t,
  ~sourceManager: SourceManager.t,
  ~reorgDetection: ReorgDetection.t,
  ~committedProgressBlockNumber: int,
  ~safeCheckpointTracking: option<SafeCheckpointTracking.t>=?,
  ~numEventsProcessed: float=?,
  ~timestampCaughtUpToHeadOrEndblock: option<Date.t>=?,
  ~isProgressAtHead: bool=?,
  ~transactionStore: TransactionStore.t=?,
  ~blockStore: BlockStore.t=?,
  ~logger: Pino.t,
) => t

let makeFromConfig: (
  Config.chain,
  ~config: Config.t,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
  ~knownHeight: int,
) => t

let makeFromDbState: (
  Config.chain,
  ~resumedChainState: Persistence.initialChainState,
  ~reorgCheckpoints: array<Internal.reorgCheckpoint>,
  ~isInReorgThreshold: bool,
  ~isRealtime: bool,
  ~config: Config.t,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
  ~reducedPollingInterval: int=?,
) => t

// Accessors.
let logger: t => Pino.t
let sourceManager: t => SourceManager.t
let chainConfig: t => Config.chain
let reorgDetection: t => ReorgDetection.t
let safeCheckpointTracking: t => option<SafeCheckpointTracking.t>
let isProgressAtHead: t => bool
let committedProgressBlockNumber: t => int
let numEventsProcessed: t => float
let pendingBudget: t => float
let startFetchingQueries: (t, ~queries: array<FetchState.query>) => unit
let timestampCaughtUpToHeadOrEndblock: t => option<Date.t>

// Metric counters, rendered by Metrics at scrape time.
let recordBlockRangeFetch: (
  t,
  ~totalTimeElapsed: float,
  ~parsingTimeElapsed: float,
  ~numEvents: int,
  ~blockRangeSize: int,
) => unit
let recordReorgDetected: (t, ~blockNumber: int) => unit
let setRollbackTargetBlock: (t, ~blockNumber: int) => unit

// Fetch-frontier reads.
let knownHeight: t => int
let contractAddresses: (t, ~contractName: string) => array<Address.t>
let bufferSize: t => int
let bufferReadyCount: t => int
let getProgressPercentage: t => float
let getProgressPercentageAt: (t, ~blockNumber: int) => float
let hasReadyItem: t => bool
let isReadyToEnterReorgThreshold: t => bool

// Fetch control.
let getNextQuery: t => FetchState.nextQuery
let dispatch: (
  t,
  ~executeQuery: FetchState.query => promise<unit>,
  ~waitForNewBlock: (~knownHeight: int) => promise<int>,
  ~onNewBlock: (~knownHeight: int) => unit,
  ~action: FetchState.nextQuery,
  ~stateId: int,
) => promise<unit>

// Views.
// Per-chain view snapshot shared by the status API, the TUI and the metrics
// renderer.
type chainData = {
  chainId: float,
  poweredByHyperSync: bool,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  numEventsProcessed: float,
  latestFetchedBlockNumber: int,
  @as("currentBlockHeight")
  knownHeight: int,
  numBatchesFetched: int,
  startBlock: int,
  endBlock: option<int>,
  numAddresses: int,
  isReady: bool,
  // Raw source height, unlike knownHeight which is clamped to endBlock.
  sourceBlockNumber: int,
  // Raw committed progress (may be -1), unlike the optional latestProcessedBlock.
  progressBlockNumber: int,
  progressLatencyMs: option<int>,
  concurrency: int,
  partitionsCount: int,
  bufferSize: int,
  // Raw buffer block (may be -1), unlike the clamped latestFetchedBlockNumber.
  bufferBlockNumber: int,
  idleSeconds: float,
  waitingForNewBlockSeconds: float,
  queryingSeconds: float,
  blockRangeFetchSeconds: float,
  blockRangeParseSeconds: float,
  blockRangeFetchCount: float,
  blockRangeFetchedEvents: float,
  blockRangeFetchedBlocks: float,
  reorgCount: int,
  reorgDetectedBlock: option<int>,
  rollbackTargetBlock: option<int>,
}
let toData: t => chainData
let toChainMetadata: t => InternalTable.Chains.metaFields
let toChainBeforeBatch: t => Batch.chainBeforeBatch
let isReadyToEnterReorgThresholdAfterBatch: (t, ~batch: Batch.t) => bool

// Derived (pure).
let hasProcessedToEndblock: t => bool
let getHighestBlockBelowThreshold: t => int
let isActivelyIndexing: t => bool
let isReady: t => bool
let isFetchingAtHead: t => bool
let isAtHeadWithoutEndBlock: t => bool

// Drop over-fetched events an address-param filter rejects, before contract
// registration runs on them. Uses the chain's current indexing addresses.
let filterByClientAddress: (t, array<Internal.item>) => array<Internal.item>

// State transitions. The chain state is mutated only through these.
let handleQueryResult: (
  t,
  ~query: FetchState.query,
  ~newItems: array<Internal.item>,
  ~newItemsWithDcs: array<Internal.item>,
  ~latestFetchedBlock: FetchState.blockNumberAndTimestamp,
  ~knownHeight: int,
  ~transactionStore: option<TransactionStore.t>,
  ~blockStore: option<BlockStore.t>,
) => unit
let materializeBatchItems: (
  t,
  ~items: array<Internal.item>,
  ~ecosystem: Ecosystem.name,
) => promise<unit>
let materializePageItems: (
  ~items: array<Internal.item>,
  ~transactionStore: option<TransactionStore.t>,
  ~blockStore: option<BlockStore.t>,
  ~ecosystem: Ecosystem.name,
) => promise<unit>
let registerReorgGuard: (
  t,
  ~blockHashes: array<ReorgDetection.blockData>,
  ~knownHeight: int,
) => ReorgDetection.reorgResult
let prepareReorg: (t, ~eventsProcessedDiff: option<float>) => unit
let updateKnownHeight: (t, ~knownHeight: int) => unit
let setEndBlockToFirstEvent: (t, ~blockNumber: int) => unit
let enterReorgThreshold: t => unit
let advanceAfterBatch: (t, ~batch: Batch.t, ~enteringReorgThreshold: bool) => unit
let applyBatchProgress: (t, ~batch: Batch.t, ~blockTimestampName: string) => unit
let markReady: t => unit
let rollback: (
  t,
  ~newProgressBlockNumber: option<int>,
  ~eventsProcessedDiff: option<float>,
  ~rollbackTargetBlockNumber: int,
  ~isReorgChain: bool,
) => unit
