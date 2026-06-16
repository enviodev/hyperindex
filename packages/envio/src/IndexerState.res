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
  mutable chainManager: ChainManager.t,
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
  ~chainManager: ChainManager.t,
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
    chainManager,
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

let setChainManager = (state: t, chainManager) => state.chainManager = chainManager

let setChainFetchers = (state: t, chainFetchers) =>
  state.chainManager = {...state.chainManager, chainFetchers}

let setChainFetcher = (state: t, ~chain, chainFetcher) =>
  state.chainManager = {
    ...state.chainManager,
    chainFetchers: state.chainManager.chainFetchers->ChainMap.set(chain, chainFetcher),
  }

// Enter the reorg threshold: shrink each fetcher's buffer by its configured
// blockLag and flip the manager flag.
let enterReorgThreshold = (state: t) => {
  Logging.info("Reorg threshold reached")
  Prometheus.ReorgThreshold.set(~isInReorgThreshold=true)

  let chainFetchers = state.chainManager.chainFetchers->ChainMap.map(chainFetcher => {
    {
      ...chainFetcher,
      fetchState: chainFetcher.fetchState->FetchState.updateInternal(
        ~blockLag=chainFetcher.chainConfig.blockLag,
      ),
    }
  })

  state.chainManager = {
    ...state.chainManager,
    chainFetchers,
    isInReorgThreshold: true,
  }
}

// Begin a reorg rollback. Commits the caller-rebuilt manager, invalidates
// in-flight fetches and enters the ReorgDetected state as one step, so the epoch
// bump can never be left out. isResolvingReorg derives from rollbackState.
let beginReorg = (state: t, ~chain, ~blockNumber, ~chainManager) => {
  state.chainManager = chainManager
  state.epoch = state.epoch + 1
  state.rollbackState = ReorgDetected({chain, blockNumber})
}

let enterFindingReorgDepth = (state: t) => state.rollbackState = FindingReorgDepth

let foundReorgDepth = (state: t, ~chain, ~rollbackTargetBlockNumber) =>
  state.rollbackState = FoundReorgDepth({chain, rollbackTargetBlockNumber})

// Finish a rollback. Commits the rolled-back manager and leaves the diff ready
// for the next batch to consume; RollbackReady makes isResolvingReorg false, so
// processing resumes to apply it.
let completeRollback = (state: t, ~eventsProcessedDiffByChain, ~chainManager) => {
  state.rollbackState = RollbackReady({eventsProcessedDiffByChain: eventsProcessedDiffByChain})
  state.chainManager = chainManager
}

let clearRollback = (state: t) => state.rollbackState = NoRollback

// Invalidate in-flight fetches/waiters without starting a rollback, eg on the
// realtime transition where the parked waiter is bound to the pre-realtime source.
let invalidateInflight = (state: t) => state.epoch = state.epoch + 1

let applyBatchProgress = (state: t, ~batch) =>
  state.chainManager = state.chainManager->ChainManager.updateProgressedChains(~batch)

// Processing-loop mutex. Guards ProcessEventBatch re-entry so only one
// processing loop runs at a time.
let isProcessing = (state: t) => state.isProcessing
let beginProcessing = (state: t) => state.isProcessing = true
let endProcessing = (state: t) => state.isProcessing = false

let recordProcessedBatch = (state: t) =>
  state.processedBatchesCount = state.processedBatchesCount + 1
