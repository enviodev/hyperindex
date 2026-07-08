// Per-chain runtime state. `t` is opaque: other modules read it through the
// accessors and change it only through the mutators exposed here.

type t

let configAddresses: Config.chain => array<Internal.indexingAddress>

let make: (
  ~chainConfig: Config.chain,
  ~fetchState: FetchState.t,
  ~indexingAddresses: IndexingAddresses.t,
  ~sourceManager: SourceManager.t,
  ~reorgDetection: ReorgDetection.t,
  ~committedProgressBlockNumber: int,
  ~safeCheckpointTracking: option<SafeCheckpointTracking.t>=?,
  ~numEventsProcessed: float=?,
  ~timestampCaughtUpToHeadOrEndblock: option<Date.t>=?,
  ~isProgressAtHead: bool=?,
  ~transactionStore: TransactionStore.t=?,
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
let reservedSize: t => float
let density: t => option<float>
let startFetchingQueries: (t, ~queries: array<FetchState.query>) => unit
let timestampCaughtUpToHeadOrEndblock: t => option<Date.t>

// Fetch-frontier reads.
let knownHeight: t => int
let contractAddresses: (t, ~contractName: string) => array<Address.t>
let bufferSize: t => int
let bufferReadyCount: t => int
let frontierBlockNumber: t => int
let fetchRange: t => int
let getProgressPercentage: t => float
let getProgressPercentageAt: (t, ~blockNumber: int) => float
let hasReadyItem: t => bool
let isReadyToEnterReorgThreshold: t => bool

// Fetch control.
let getQueries: (t, ~chainTargetItems: int, ~budget: int) => FetchState.nextQuery
let dispatch: (
  t,
  ~executeQuery: FetchState.query => promise<unit>,
  ~waitForNewBlock: (~knownHeight: int) => promise<int>,
  ~onNewBlock: (~knownHeight: int) => unit,
  ~action: FetchState.nextQuery,
  ~stateId: int,
) => promise<unit>

// Views.
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
}
let toChainData: t => chainData
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

// State transitions. The chain state is mutated only through these.
let handleQueryResult: (
  t,
  ~query: FetchState.query,
  ~newItems: array<Internal.item>,
  ~newItemsWithDcs: array<Internal.item>,
  ~latestFetchedBlock: FetchState.blockNumberAndTimestamp,
  ~knownHeight: int,
  ~transactionStore: option<TransactionStore.t>,
) => unit
let materializeBatchItems: (t, ~items: array<Internal.item>) => promise<unit>
let materializePageItems: (
  ~items: array<Internal.item>,
  ~page: option<TransactionStore.t>,
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
let applyBatchProgress: (t, ~batch: Batch.t) => unit
let markReady: t => unit
let rollback: (
  t,
  ~newProgressBlockNumber: option<int>,
  ~eventsProcessedDiff: option<float>,
  ~rollbackTargetBlockNumber: int,
  ~isReorgChain: bool,
) => unit
