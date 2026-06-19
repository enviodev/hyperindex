type chain = ChainMap.Chain.t
type rollbackState =
  | NoRollback
  | ReorgDetected({chain: chain, blockNumber: int})
  | FindingReorgDepth
  | FoundReorgDepth({chain: chain, rollbackTargetBlockNumber: int})
  | RollbackReady({eventsProcessedDiffByChain: dict<float>})

module WriteThrottlers = {
  type t = {pruneStaleEntityHistory: Throttler.t}
  let make = (): t => {
    let pruneStaleEntityHistory = {
      let intervalMillis = Env.ThrottleWrites.pruneStaleDataIntervalMillis
      let logger = Logging.createChild(
        ~params={
          "context": "Throttler for pruning stale entity history data",
          "intervalMillis": intervalMillis,
        },
      )
      Throttler.make(~intervalMillis, ~logger)
    }
    {pruneStaleEntityHistory: pruneStaleEntityHistory}
  }
}

module EntityTables = {
  type t = dict<InMemoryTable.Entity.t>
  exception UndefinedEntity({entityName: string})
  let make = (entities: array<Internal.entityConfig>): t => {
    let init = Dict.make()
    entities->Array.forEach(entityConfig => {
      init->Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
    })
    init
  }

  let get = (self: t, ~entityName: string) => {
    switch self->Utils.Dict.dangerouslyGetNonOption(entityName) {
    | Some(table) => table
    | None =>
      UndefinedEntity({entityName: entityName})->ErrorHandling.mkLogAndRaise(
        ~msg="Unexpected, entity InMemoryTable is undefined",
      )
    }
  }
}

type effectCacheInMemTable = {
  // Cache keys whose handler output is persisted on the next write. Drained
  // each write; eviction is driven by the per-entry checkpointId instead.
  mutable idsToStore: array<string>,
  mutable invalidationsCount: int,
  // Each entry is stamped with the checkpoint that referenced it (or
  // loadedFromDbCheckpointId for db reads), so committed entries can be
  // dropped once persisted/re-derivable, mirroring entity changes.
  mutable dict: dict<Change.t<Internal.effectOutput>>,
  mutable changesCount: float,
  effect: Internal.effect,
}

type t = {
  config: Config.t,
  persistence: Persistence.t,
  // --- In-memory store: entity/effect tables and the pending-write queue. ---
  allEntities: array<Internal.entityConfig>,
  mutable entities: EntityTables.t,
  mutable effects: dict<effectCacheInMemTable>,
  mutable rollback: option<Persistence.rollback>,
  // Last checkpoint persisted to the db.
  mutable committedCheckpointId: Internal.checkpointId,
  // Processing frontier; runs ahead of committedCheckpointId while writes lag.
  mutable processedCheckpointId: Internal.checkpointId,
  // Processed but unwritten. The cycle drains them, splitting each write at a
  // change in isInReorgThreshold so it never mixes history-saving modes.
  mutable processedBatches: array<Batch.t>,
  // Count of processed batches; version-independent progress counter.
  mutable processedBatchesCount: int,
  // The single in-flight write loop, None when idle.
  mutable writeFiber: option<promise<unit>>,
  // Set once a write throws, to stop the loop. The error itself goes to onError.
  mutable hasFailedWrite: bool,
  // Resolved after every commit so capacity/flush waiters can re-evaluate.
  mutable commitWaiters: array<unit => unit>,
  // Latest metadata staged per chain; used to skip unchanged restages.
  mutable chainMeta: dict<InternalTable.Chains.metaFields>,
  // Set on a real change. Folded into a batch write, else flushed on the throttle.
  mutable chainMetaDirty: bool,
  // Throttles metadata-only writes when no batches flow.
  chainMetaThrottler: Throttler.t,
  // True while a batch is being processed; guards ProcessEventBatch re-entry.
  mutable isProcessing: bool,
  // Whole-indexer view over every chain's runtime state plus the run-wide flags
  // derived from it. Mutated in place through CrossChainState.
  crossChainState: CrossChainState.t,
  mutable rollbackState: rollbackState,
  indexerStartTime: Date.t,
  writeThrottlers: WriteThrottlers.t,
  loadManager: LoadManager.t,
  keepProcessAlive: bool,
  exitAfterFirstEventBlock: bool,
  // The single fatal-error handler.
  onError: ErrorHandling.t => unit,
  // Set once on any fatal error. Every loop checks it to stop iterating and
  // every launch skips when it's set, so a single failure quiesces the indexer.
  mutable isStopped: bool,
  // Bumped when in-flight fetch work must be invalidated: on a reorg (responses
  // requested against pre-reorg state) and on the realtime transition (the
  // waitForNewBlock waiter is bound to the old, pre-realtime source). A fetch
  // response or waiter carrying an older epoch than this is discarded.
  mutable epoch: int,
}

let make = (
  ~config: Config.t,
  ~persistence: Persistence.t,
  ~chainStates: dict<ChainState.t>,
  ~isInReorgThreshold: bool,
  ~isRealtime: bool,
  ~maxBackfillConcurrency=Env.maxBackfillConcurrency,
  ~maxRealtimeConcurrency=Env.maxRealtimeConcurrency,
  ~targetBufferSize=CrossChainState.calculateTargetBufferSize(),
  ~committedCheckpointId=Internal.initialCheckpointId,
  ~isDevelopmentMode=false,
  ~shouldUseTui=false,
  ~exitAfterFirstEventBlock=false,
  ~onError: ErrorHandling.t => unit,
) => {
  let chainMetaThrottler = {
    let intervalMillis = Env.ThrottleWrites.chainMetadataIntervalMillis
    Throttler.make(
      ~intervalMillis,
      ~logger=Logging.createChild(
        ~params={
          "context": "Throttler for chain metadata writes",
          "intervalMillis": intervalMillis,
        },
      ),
    )
  }

  {
    config,
    persistence,
    allEntities: persistence.allEntities,
    entities: EntityTables.make(persistence.allEntities),
    effects: Dict.make(),
    rollback: None,
    committedCheckpointId,
    processedCheckpointId: committedCheckpointId,
    processedBatches: [],
    processedBatchesCount: 0,
    writeFiber: None,
    hasFailedWrite: false,
    commitWaiters: [],
    chainMeta: Dict.make(),
    chainMetaDirty: false,
    chainMetaThrottler,
    isProcessing: false,
    crossChainState: CrossChainState.make(
      ~chainStates,
      ~isInReorgThreshold,
      ~isRealtime,
      ~maxBackfillConcurrency,
      ~maxRealtimeConcurrency,
      ~targetBufferSize,
    ),
    indexerStartTime: Date.make(),
    rollbackState: NoRollback,
    writeThrottlers: WriteThrottlers.make(),
    loadManager: LoadManager.make(),
    keepProcessAlive: isDevelopmentMode || shouldUseTui,
    exitAfterFirstEventBlock,
    onError,
    isStopped: false,
    epoch: 0,
  }
}

// Check if progress is past the reorg threshold (safe block).
// A chain is in reorg threshold when progressBlockNumber > sourceBlockNumber - maxReorgDepth.
// This matches the logic in InternalTable.Checkpoints.makeGetReorgCheckpointsQuery.
let isProgressInReorgThreshold = (~progressBlockNumber, ~sourceBlockNumber, ~maxReorgDepth) => {
  maxReorgDepth > 0 &&
  sourceBlockNumber > 0 &&
  progressBlockNumber > sourceBlockNumber - maxReorgDepth
}

let makeFromDbState = (
  ~config: Config.t,
  ~persistence: Persistence.t,
  ~initialState: Persistence.initialState,
  ~registrations,
  ~isDevelopmentMode=false,
  ~shouldUseTui=false,
  ~exitAfterFirstEventBlock=false,
  ~reducedPollingInterval=?,
  ~maxBackfillConcurrency=Env.maxBackfillConcurrency,
  ~maxRealtimeConcurrency=Env.maxRealtimeConcurrency,
  ~targetBufferSize=CrossChainState.calculateTargetBufferSize(),
  ~onError,
) => {
  let isInReorgThreshold = if initialState.cleanRun {
    false
  } else {
    // Check if any chain is in reorg threshold by comparing progress with sourceBlock - maxReorgDepth.
    initialState.chains->Array.some(chain =>
      isProgressInReorgThreshold(
        ~progressBlockNumber=chain.progressBlockNumber,
        ~sourceBlockNumber=chain.sourceBlockNumber,
        ~maxReorgDepth=chain.maxReorgDepth,
      )
    )
  }

  Prometheus.ProcessingMaxBatchSize.set(~maxBatchSize=config.batchSize)
  Prometheus.ReorgThreshold.set(~isInReorgThreshold)
  initialState.cache->Utils.Dict.forEach(({effectName, count}) => {
    Prometheus.EffectCacheCount.set(~count, ~effectName)
  })

  // updateSyncTimeOnRestart wipes the saved timestamp so a restart re-enters
  // backfill mode for all chains.
  let isRealtime =
    !Env.updateSyncTimeOnRestart &&
    initialState.chains->Array.length > 0 &&
    initialState.chains->Array.every(c => c.timestampCaughtUpToHeadOrEndblock->Option.isSome)

  let chainStates = Dict.make()
  initialState.chains->Array.forEach((resumedChainState: Persistence.initialChainState) => {
    let chain = Config.getChain(config, ~chainId=resumedChainState.id)
    let chainConfig = config.chainMap->ChainMap.get(chain)
    chainStates->Utils.Dict.setByInt(
      resumedChainState.id,
      chainConfig->ChainState.makeFromDbState(
        ~resumedChainState,
        ~reorgCheckpoints=initialState.reorgCheckpoints,
        ~isInReorgThreshold,
        ~isRealtime,
        ~config,
        ~registrations,
        ~reducedPollingInterval?,
      ),
    )
  })

  // Set initial progress metrics from DB state so dashboards reflect
  // the persisted state immediately on restart
  let allChainsReady = ref(initialState.chains->Array.length > 0)
  chainStates->Utils.Dict.forEach(cs => {
    let chainId = (cs->ChainState.chainConfig).id
    Prometheus.ProgressBlockNumber.set(
      ~blockNumber=cs->ChainState.committedProgressBlockNumber,
      ~chainId,
    )
    Prometheus.ProgressReady.init(~chainId)
    if cs->ChainState.isReady {
      Prometheus.ProgressReady.set(~chainId)
    } else {
      allChainsReady := false
    }
  })
  if allChainsReady.contents {
    Prometheus.ProgressReady.setAllReady()
  }

  make(
    ~config,
    ~persistence,
    ~chainStates,
    ~isInReorgThreshold,
    ~isRealtime,
    ~maxBackfillConcurrency,
    ~maxRealtimeConcurrency,
    ~targetBufferSize,
    ~committedCheckpointId=initialState.checkpointId,
    ~isDevelopmentMode,
    ~shouldUseTui,
    ~exitAfterFirstEventBlock,
    ~onError,
  )
}

// A fetch response or new-block waiter is stale once the indexer stopped or the
// epoch moved on (reorg / realtime transition) since the work was scheduled.
@inline
let isStale = (state: t, ~stateId) => state.isStopped || stateId !== state.epoch

// True from when a reorg is detected until its rollback target is resolved.
// Fetching and batch processing pause while it holds so they don't act on chain
// state that's about to be rolled back. Once RollbackReady, processing resumes to
// apply the diff, so this reads false there.
let isResolvingReorg = (state: t) =>
  switch state.rollbackState {
  | ReorgDetected(_) | FindingReorgDepth | FoundReorgDepth(_) => true
  | NoRollback | RollbackReady(_) => false
  }

// The single fatal-error handler. Stops every loop before reporting, and only
// reports the first error so redundant handlers (eg an error caught in two
// nested scopes) don't double-report.
@inline
let errorExit = (state: t, errHandler) =>
  if !state.isStopped {
    state.isStopped = true
    state.onError(errHandler)
  }

let unexpectedErrorMsg = "Indexer has failed with an unexpected error"

// Halt the loops without reporting an error, eg to hand the shared db over to a
// resumed indexer in tests.
let stop = (state: t) => state.isStopped = true

let getChainState = (state: t, ~chain: chain): ChainState.t =>
  switch state.crossChainState
  ->CrossChainState.chainStates
  ->Utils.Dict.dangerouslyGetByIntNonOption(chain->ChainMap.Chain.toChainId) {
  | Some(cs) => cs
  | None =>
    // Should be unreachable, since we validate on Chain.t creation
    JsError.throwWithMessage(
      "No chain with id " ++ chain->ChainMap.Chain.toString ++ " found in chain states",
    )
  }

let getSafeCheckpointId = (state: t) => state.crossChainState->CrossChainState.getSafeCheckpointId

let createBatch = (
  state: t,
  ~processedCheckpointId,
  ~batchSizeTarget: int,
  ~isRollback: bool,
): Batch.t =>
  state.crossChainState->CrossChainState.createBatch(
    ~processedCheckpointId,
    ~batchSizeTarget,
    ~isRollback,
  )

let enterReorgThreshold = (state: t) => state.crossChainState->CrossChainState.enterReorgThreshold

// Begin a reorg rollback. Invalidates in-flight fetches and enters the
// ReorgDetected state as one step, so the epoch bump can never be left out. The
// caller has already mutated the chain states (restored counters, reset pending
// queries). isResolvingReorg derives from rollbackState.
let beginReorg = (state: t, ~chain, ~blockNumber) => {
  state.epoch = state.epoch + 1
  state.rollbackState = ReorgDetected({chain, blockNumber})
}

let enterFindingReorgDepth = (state: t) => state.rollbackState = FindingReorgDepth

let foundReorgDepth = (state: t, ~chain, ~rollbackTargetBlockNumber) =>
  state.rollbackState = FoundReorgDepth({chain, rollbackTargetBlockNumber})

// Finish a rollback. The caller has already rolled the chain states back in
// place; this leaves the diff ready for the next batch to consume.
// RollbackReady makes isResolvingReorg false, so processing resumes to apply it.
let completeRollback = (state: t, ~eventsProcessedDiffByChain) => {
  state.rollbackState = RollbackReady({eventsProcessedDiffByChain: eventsProcessedDiffByChain})
}

let clearRollback = (state: t) => state.rollbackState = NoRollback

// Invalidate in-flight fetches/waiters without starting a rollback, eg on the
// realtime transition where the parked waiter is bound to the pre-realtime source.
let invalidateInflight = (state: t) => state.epoch = state.epoch + 1

let applyBatchProgress = (state: t, ~batch: Batch.t) =>
  state.crossChainState->CrossChainState.applyBatchProgress(~batch)

// Processing-loop mutex. Guards ProcessEventBatch re-entry so only one
// processing loop runs at a time.
let isProcessing = (state: t) => state.isProcessing
let beginProcessing = (state: t) => state.isProcessing = true
let endProcessing = (state: t) => state.isProcessing = false

let recordProcessedBatch = (state: t) =>
  state.processedBatchesCount = state.processedBatchesCount + 1

// --- Read accessors. The type is abstract in the interface; modules read state
// through these and change it only through the transitions above and the domain
// operations below. Accessors returning a mutable dict/array let callers mutate
// the container in place (eg insert an entity table). ---

let config = (state: t) => state.config
let persistence = (state: t) => state.persistence
let allEntities = (state: t) => state.allEntities
let entities = (state: t) => state.entities
let effects = (state: t) => state.effects
let committedCheckpointId = (state: t) => state.committedCheckpointId
let processedCheckpointId = (state: t) => state.processedCheckpointId
let processedBatches = (state: t) => state.processedBatches
let processedBatchesCount = (state: t) => state.processedBatchesCount
let writeFiber = (state: t) => state.writeFiber
let hasFailedWrite = (state: t) => state.hasFailedWrite
let chainMetaDirty = (state: t) => state.chainMetaDirty
let chainMetaThrottler = (state: t) => state.chainMetaThrottler
let crossChainState = (state: t) => state.crossChainState
let chainStates = (state: t) => state.crossChainState->CrossChainState.chainStates
let isInReorgThreshold = (state: t) => state.crossChainState->CrossChainState.isInReorgThreshold
let isRealtime = (state: t) => state.crossChainState->CrossChainState.isRealtime
let rollbackState = (state: t) => state.rollbackState
let indexerStartTime = (state: t) => state.indexerStartTime
let loadManager = (state: t) => state.loadManager
let keepProcessAlive = (state: t) => state.keepProcessAlive
let exitAfterFirstEventBlock = (state: t) => state.exitAfterFirstEventBlock
let isStopped = (state: t) => state.isStopped
let epoch = (state: t) => state.epoch
let pruneStaleEntityHistoryThrottler = (state: t) => state.writeThrottlers.pruneStaleEntityHistory

// --- Store domain operations. ---

// Queue a processed batch for writing and advance the processing frontier.
let queueProcessedBatch = (state: t, ~batch: Batch.t) => {
  state.processedBatches->Array.push(batch)->ignore
  switch batch.checkpointIds->Utils.Array.last {
  | Some(checkpointId) => state.processedCheckpointId = checkpointId
  | None => ()
  }
}

// Take the leading run of queued batches sharing isInReorgThreshold as one merged
// batch, leaving the rest queued for the next write. Caller guarantees the queue
// is non-empty.
let drainBatchRun = (state: t): Batch.t => {
  let all = state.processedBatches
  let isInReorgThreshold = (all->Array.getUnsafe(0)).isInReorgThreshold

  let rest = []
  let progressedChainsById = Dict.make()
  let totalBatchSize = ref(0)
  let items = []
  let checkpointIds = []
  let checkpointChainIds = []
  let checkpointBlockNumbers = []
  let checkpointBlockHashes = []
  let checkpointEventsProcessed = []
  all->Array.forEach(batch => {
    // Once one batch lands in rest, all later ones follow it, preserving order.
    if rest->Utils.Array.isEmpty && batch.isInReorgThreshold == isInReorgThreshold {
      batch.progressedChainsById->Utils.Dict.forEachWithKey((chainAfterBatch, key) =>
        progressedChainsById->Dict.set(key, chainAfterBatch)
      )
      totalBatchSize := totalBatchSize.contents + batch.totalBatchSize
      items->Array.pushMany(batch.items)
      checkpointIds->Array.pushMany(batch.checkpointIds)
      checkpointChainIds->Array.pushMany(batch.checkpointChainIds)
      checkpointBlockNumbers->Array.pushMany(batch.checkpointBlockNumbers)
      checkpointBlockHashes->Array.pushMany(batch.checkpointBlockHashes)
      checkpointEventsProcessed->Array.pushMany(batch.checkpointEventsProcessed)
    } else {
      rest->Array.push(batch)
    }
  })
  state.processedBatches = rest

  {
    totalBatchSize: totalBatchSize.contents,
    items,
    progressedChainsById,
    isInReorgThreshold,
    checkpointIds,
    checkpointChainIds,
    checkpointBlockNumbers,
    checkpointBlockHashes,
    checkpointEventsProcessed,
  }
}

// Take the pending rollback diff to write, clearing it from the store.
let takeRollback = (state: t): option<Persistence.rollback> => {
  let rollback = state.rollback
  state.rollback = None
  rollback
}

// Advance the committed (durably persisted) frontier after a successful write.
let markCommitted = (state: t, ~upToCheckpointId) => state.committedCheckpointId = upToCheckpointId

// Reset the in-memory tables and arm the rollback diff that the next write commits.
let beginRollbackDiff = (
  state: t,
  ~targetCheckpointId,
  ~diffCheckpointId,
  ~progressBlockNumberByChainId,
) => {
  state.entities = EntityTables.make(state.allEntities)
  state.effects = Dict.make()
  state.rollback = Some({
    targetCheckpointId,
    diffCheckpointId,
    progressBlockNumberByChainId,
  })
}

// Stop the write loop and surface the failure; the error itself goes to onError.
let recordWriteFailure = (state: t, exn) => {
  state.hasFailedWrite = true
  state.onError(exn->ErrorHandling.make(~msg="Failed writing batch to the database"))
}

let beginWriteFiber = (state: t, fiber) => state.writeFiber = Some(fiber)
let endWriteFiber = (state: t) => state.writeFiber = None

// Resolve and clear everyone waiting on a commit so they can re-evaluate.
let wakeCommitWaiters = (state: t) => {
  let waiters = state.commitWaiters
  state.commitWaiters = []
  waiters->Array.forEach(resolve => resolve())
}

let addCommitWaiter = (state: t, resolve) => state.commitWaiters->Array.push(resolve)->ignore

let metaFieldsEqual = (a: InternalTable.Chains.metaFields, b: InternalTable.Chains.metaFields) =>
  a.firstEventBlockNumber == b.firstEventBlockNumber &&
  a.latestFetchedBlockNumber == b.latestFetchedBlockNumber &&
  a.isHyperSync == b.isHyperSync &&
  // Date is boxed; compare epoch ms.
  a.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime) ==
    b.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime)

// Stage per-chain metadata, dirtying only on a real change so restages are no-ops.
let stageChainMeta = (state: t, chainsData: dict<InternalTable.Chains.metaFields>) =>
  chainsData->Utils.Dict.forEachWithKey((meta, chainId) => {
    let changed = switch state.chainMeta->Utils.Dict.dangerouslyGetNonOption(chainId) {
    | Some(prev) => !metaFieldsEqual(meta, prev)
    | None => true
    }
    if changed {
      state.chainMeta->Dict.set(chainId, meta)
      state.chainMetaDirty = true
    }
  })

// Take a snapshot of staged metadata to write, clearing the dirty flag. A restage
// during the in-flight write re-dirties it and is rewritten next iteration.
let takeChainMetaSnapshot = (state: t): option<dict<InternalTable.Chains.metaFields>> =>
  if state.chainMetaDirty {
    state.chainMetaDirty = false
    Some(state.chainMeta->Utils.Dict.shallowCopy)
  } else {
    None
  }
