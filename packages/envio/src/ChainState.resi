// Per-chain runtime state. `t` is opaque: other modules read it through the
// accessors and change it only through the mutators exposed here.

type t

let configAddresses: Config.chain => array<Internal.indexingAddress>

let make: (
  ~chainConfig: Config.chain,
  ~fetchState: FetchState.t,
  ~sourceManager: SourceManager.t,
  ~reorgDetection: ReorgDetection.t,
  ~committedProgressBlockNumber: int,
  ~safeCheckpointTracking: option<SafeCheckpointTracking.t>=?,
  ~numEventsProcessed: float=?,
  ~timestampCaughtUpToHeadOrEndblock: option<Date.t>=?,
  ~isProgressAtHead: bool=?,
  ~logger: Pino.t,
) => t

let makeFromConfig: (
  Config.chain,
  ~config: Config.t,
  ~registrations: HandlerRegister.registrations,
  ~targetBufferSize: int,
  ~knownHeight: int,
) => t

let makeFromDbState: (
  Config.chain,
  ~resumedChainState: Persistence.initialChainState,
  ~reorgCheckpoints: array<Internal.reorgCheckpoint>,
  ~isInReorgThreshold: bool,
  ~isRealtime: bool,
  ~config: Config.t,
  ~registrations: HandlerRegister.registrations,
  ~targetBufferSize: int,
  ~reducedPollingInterval: int=?,
) => t

// Accessors.
let logger: t => Pino.t
let fetchState: t => FetchState.t
let sourceManager: t => SourceManager.t
let chainConfig: t => Config.chain
let reorgDetection: t => ReorgDetection.t
let safeCheckpointTracking: t => option<SafeCheckpointTracking.t>
let transactionStore: t => TransactionStore.t
let isProgressAtHead: t => bool
let committedProgressBlockNumber: t => int
let numEventsProcessed: t => float
let timestampCaughtUpToHeadOrEndblock: t => option<Date.t>

// Derived (pure).
let hasProcessedToEndblock: t => bool
let hasNoMoreEventsToProcess: t => bool
let getHighestBlockBelowThreshold: t => int
let isActivelyIndexing: t => bool
let isReady: t => bool
let isFetchingAtHead: t => bool

// State transitions. The chain state is mutated only through these.
let handleQueryResult: (
  t,
  ~query: FetchState.query,
  ~newItems: array<Internal.item>,
  ~newItemsWithDcs: array<Internal.item>,
  ~latestFetchedBlock: FetchState.blockNumberAndTimestamp,
  ~knownHeight: int,
  ~transactionStore: TransactionStore.t,
) => unit
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
let applyBatchProgress: (
  t,
  ~batch: Batch.t,
  ~allChainsAtHead: bool,
  ~nextQueueItemIsNone: bool,
) => unit
let rollback: (
  t,
  ~newProgressBlockNumber: option<int>,
  ~eventsProcessedDiff: option<float>,
  ~rollbackTargetBlockNumber: int,
  ~isReorgChain: bool,
) => unit
