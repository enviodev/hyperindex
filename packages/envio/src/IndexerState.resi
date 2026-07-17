// The indexer state. `t` is opaque: other modules read it through the accessors
// and change it only through the transitions and setters exposed here.

type chain = ChainMap.Chain.t

type rollbackState =
  | NoRollback
  | ReorgDetected({chain: chain, blockNumber: int})
  | FindingReorgDepth
  | FoundReorgDepth({chain: chain, rollbackTargetBlockNumber: int})
  | RollbackReady({eventsProcessedDiffByChain: dict<float>})

// Metric counters rendered by Metrics at scrape time. The records are exposed
// read-only through the accessors below; mutation goes through the record*
// operations.
type handlerStat = {
  contract: string,
  event: string,
  mutable processingSeconds: float,
  // Floats: cumulative counters outgrow int32.
  mutable processingCount: float,
  mutable preloadSeconds: float,
  mutable preloadCount: float,
  mutable preloadSecondsTotal: float,
  mutable preloadPendingCount: int,
  mutable preloadPendingTimerRef: Performance.timeRef,
}

type storageLoadStat = {
  operation: string,
  storage: string,
  mutable seconds: float,
  mutable secondsTotal: float,
  mutable count: float,
  mutable whereSize: float,
  mutable size: float,
  mutable pendingCount: int,
  mutable pendingTimerRef: Performance.timeRef,
}

type storageWriteStat = {
  storage: string,
  mutable seconds: float,
  mutable count: int,
}

type historyPruneStat = {
  mutable seconds: float,
  mutable count: int,
}

module EntityTables: {
  type t = dict<InMemoryTable.Entity.t>
  let make: array<Internal.entityConfig> => t
  let get: (t, ~entityName: string) => InMemoryTable.Entity.t
}

type t

let make: (
  ~config: Config.t,
  ~persistence: Persistence.t,
  ~chainStates: dict<ChainState.t>,
  ~isInReorgThreshold: bool,
  ~isRealtime: bool,
  ~targetBufferSize: int=?,
  ~committedCheckpointId: Internal.checkpointId=?,
  ~isDevelopmentMode: bool=?,
  ~shouldUseTui: bool=?,
  ~exitAfterFirstEventBlock: bool=?,
  ~onError: ErrorHandling.t => unit,
) => t

let makeFromDbState: (
  ~config: Config.t,
  ~persistence: Persistence.t,
  ~initialState: Persistence.initialState,
  ~registrationsByChainId: HandlerRegister.registrationsByChainId,
  ~isDevelopmentMode: bool=?,
  ~shouldUseTui: bool=?,
  ~exitAfterFirstEventBlock: bool=?,
  ~reducedPollingInterval: int=?,
  ~targetBufferSize: int=?,
  ~onError: ErrorHandling.t => unit,
) => t

let unexpectedErrorMsg: string

// Read guards / transitions.
let isStale: (t, ~stateId: int) => bool
let isResolvingReorg: t => bool
let errorExit: (t, ErrorHandling.t) => unit
let stop: t => unit
let getChainState: (t, ~chain: chain) => ChainState.t
let enterReorgThreshold: t => unit
let beginReorg: (t, ~chain: chain, ~blockNumber: int) => unit
let enterFindingReorgDepth: t => unit
let foundReorgDepth: (t, ~chain: chain, ~rollbackTargetBlockNumber: int) => unit
let completeRollback: (t, ~eventsProcessedDiffByChain: dict<float>) => unit
let clearRollback: t => unit
let invalidateInflight: t => unit
let applyBatchProgress: (t, ~batch: Batch.t) => unit
let isProcessing: t => bool
let beginProcessing: t => unit
let endProcessing: t => unit
let recordProcessedBatch: t => unit
let createBatch: (
  t,
  ~processedCheckpointId: Internal.checkpointId,
  ~batchSizeTarget: int,
  ~isRollback: bool,
) => Batch.t
let getSafeCheckpointId: t => option<Internal.checkpointId>

// Accessors.
let config: t => Config.t
let persistence: t => Persistence.t
let allEntities: t => array<Internal.entityConfig>
let entities: t => EntityTables.t
let effectState: t => EffectState.t
let committedCheckpointId: t => Internal.checkpointId
let processedCheckpointId: t => Internal.checkpointId
let processedBatches: t => array<Batch.t>
let processedBatchesCount: t => int
let writeFiber: t => option<promise<unit>>
let hasFailedWrite: t => bool
let chainMetaDirty: t => bool
let chainMetaThrottler: t => Throttler.t
let crossChainState: t => CrossChainState.t
let chainStates: t => dict<ChainState.t>
let isInReorgThreshold: t => bool
let isRealtime: t => bool
let rollbackState: t => rollbackState
let indexerStartTime: t => Date.t
let loadManager: t => LoadManager.t
let keepProcessAlive: t => bool
let exitAfterFirstEventBlock: t => bool
let isStopped: t => bool
let epoch: t => int
let pruneStaleEntityHistoryThrottler: t => Throttler.t
let simulateDeadInputTracker: t => option<SimulateDeadInputTracker.t>
let preloadSeconds: t => float
let processingSeconds: t => float
let handlerStats: t => dict<handlerStat>
let storageLoadStats: t => dict<storageLoadStat>
let storageWriteStats: t => dict<storageWriteStat>
let historyPruneStats: t => dict<historyPruneStat>
let rollbackSeconds: t => float
let rollbackCount: t => int
let rollbackEventsCount: t => float

// Metric counters.
let recordBatchDurations: (t, ~loadDuration: float, ~handlerDuration: float) => unit
let recordHandlerDuration: (t, ~contract: string, ~event: string, ~duration: float) => unit
let startPreloadHandler: (t, ~contract: string, ~event: string) => Performance.timeRef
let endPreloadHandler: (t, Performance.timeRef, ~contract: string, ~event: string) => unit
let startStorageLoad: (t, ~storage: string, ~operation: string) => Performance.timeRef
let endStorageLoad: (
  t,
  Performance.timeRef,
  ~storage: string,
  ~operation: string,
  ~whereSize: int,
  ~size: int,
) => unit
let recordStorageWrite: (t, ~storage: string, ~timeSeconds: float) => unit
let recordHistoryPrune: (t, ~entityName: string, ~timeSeconds: float) => unit
let recordRollbackSuccess: (t, ~timeSeconds: float, ~rollbackedProcessedEvents: float) => unit

// Store domain operations.
let queueProcessedBatch: (t, ~batch: Batch.t) => unit
let drainBatchRun: t => Batch.t
let takeRollback: t => option<Persistence.rollback>
let markCommitted: (t, ~upToCheckpointId: Internal.checkpointId) => unit
let beginRollbackDiff: (
  t,
  ~targetCheckpointId: Internal.checkpointId,
  ~diffCheckpointId: Internal.checkpointId,
  ~progressBlockNumberByChainId: dict<int>,
) => unit
let recordWriteFailure: (t, exn) => unit
let beginWriteFiber: (t, promise<unit>) => unit
let endWriteFiber: t => unit
let wakeCommitWaiters: t => unit
let addCommitWaiter: (t, unit => unit) => unit
let stageChainMeta: (t, dict<InternalTable.Chains.metaFields>) => unit
let takeChainMetaSnapshot: t => option<dict<InternalTable.Chains.metaFields>>
