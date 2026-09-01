// The indexer state. `t` is opaque: other modules read it through the accessors
// and change it only through the transitions and setters exposed here.


type rollbackState =
  | NoRollback
  | ReorgDetected({chainId: ChainId.t, blockNumber: int})
  | FindingReorgDepth
  | FoundReorgDepth({chainId: ChainId.t, rollbackTargetBlockNumber: int})
  | RollbackReady({eventsProcessedDiffByChain: dict<float>})

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
  ~onExit: unit => unit=?,
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
  ~onExit: unit => unit=?,
) => t

let unexpectedErrorMsg: string

// Read guards / transitions.
let isStale: (t, ~stateId: int) => bool
let isResolvingReorg: t => bool
let errorExit: (t, ErrorHandling.t) => unit
let stop: t => unit
let getChainState: (t, ~chainId: ChainId.t) => ChainState.t
let enterReorgThreshold: t => unit
let beginReorg: (t, ~chainId: ChainId.t, ~blockNumber: int) => unit
let enterFindingReorgDepth: t => unit
let foundReorgDepth: (t, ~chainId: ChainId.t, ~rollbackTargetBlockNumber: int) => unit
let completeRollback: (t, ~eventsProcessedDiffByChain: dict<float>) => unit
let clearRollback: t => unit
let invalidateInflight: t => unit
let applyBatchProgress: (t, ~batch: Batch.t) => unit
let isProcessing: t => bool
let beginProcessing: t => unit
let endProcessing: t => unit
let markProcessingStalledOnFetch: t => unit
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
let eachEntityTable: (
  t,
  (
    ~entityConfig: Internal.entityConfig,
    ~scope: Internal.chainScope,
    ~table: InMemoryTable.Entity.t,
  ) => unit,
) => unit
let effectState: t => EffectState.t
let committedCheckpointId: t => Internal.checkpointId
let processedCheckpointId: t => Internal.checkpointId
let processedBatches: t => array<Batch.t>
let processedBatchesCount: t => int
let writeFiber: t => option<promise<unit>>
let finalizeFiber: t => option<promise<unit>>
let hasFailedWrite: t => bool
let chainMetaDirty: t => bool
let chainMetaThrottler: t => Throttler.t
let crossChainState: t => CrossChainState.t
let chainStates: t => dict<ChainState.t>
let isInReorgThreshold: t => bool
let isRealtime: t => bool
let isFinalizingIndexes: t => bool
let markCaughtUpIfSettled: t => unit
let markReady: (t, ~readyAt: Date.t) => unit
let rollbackState: t => rollbackState
let indexerStartTime: t => Date.t
let loadManager: t => LoadManager.t
let keepProcessAlive: t => bool
let exitAfterFirstEventBlock: t => bool
let onExit: t => option<unit => unit>
let isStopped: t => bool
let epoch: t => int
let lastPrunedAtMillis: t => dict<float>
let simulateDeadInputTracker: t => option<SimulateDeadInputTracker.t>

// Read-only snapshot of every metric; the single window into the mutable
// counters for the /metrics endpoint, the TUI and the console API.
let toMetrics: t => Metrics.t

// Metric counters.
let recordBatchDurations: (t, ~loadDuration: float, ~handlerDuration: float) => unit
let recordStalledOnStorageWrite: (t, ~seconds: float) => unit
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
  ~rolledBackAddresses: array<AddressRows.key>,
) => unit
let recordWriteFailure: (t, exn) => unit
let beginWriteFiber: (t, promise<unit>) => unit
let endWriteFiber: t => unit
let beginFinalizeFiber: (t, promise<unit>) => unit
let endFinalizeFiber: t => unit
let wakeCommitWaiters: t => unit
let addCommitWaiter: (t, unit => unit) => unit
let stageChainMeta: (t, dict<InternalTable.Chains.metaFields>) => unit
let takeChainMetaSnapshot: t => option<dict<InternalTable.Chains.metaFields>>
