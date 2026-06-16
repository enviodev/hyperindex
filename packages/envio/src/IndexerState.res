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

type t = {
  ctx: Ctx.t,
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
  // True from the moment a reorg is detected until its rollback is applied.
  // Fetching and batch processing pause while it's set so they can't act on
  // chain state that's about to be rolled back.
  mutable isRollingBack: bool,
  // Bumped when in-flight fetch work must be invalidated: on a reorg (responses
  // requested against pre-reorg state) and on the realtime transition (the
  // waitForNewBlock waiter is bound to the old, pre-realtime source). A fetch
  // response or waiter carrying an older epoch than this is discarded.
  mutable epoch: int,
}

let make = (
  ~ctx: Ctx.t,
  ~chainManager: ChainManager.t,
  ~isDevelopmentMode=false,
  ~shouldUseTui=false,
  ~exitAfterFirstEventBlock=false,
  ~onError: ErrorHandling.t => unit,
) => {
  {
    ctx,
    chainManager,
    indexerStartTime: Date.make(),
    rollbackState: NoRollback,
    writeThrottlers: WriteThrottlers.make(),
    loadManager: LoadManager.make(),
    keepProcessAlive: isDevelopmentMode || shouldUseTui,
    exitAfterFirstEventBlock,
    onError,
    isStopped: false,
    isRollingBack: false,
    epoch: 0,
  }
}

// A fetch response or new-block waiter is stale once the indexer stopped or the
// epoch moved on (reorg / realtime transition) since the work was scheduled.
@inline
let isStale = (state: t, ~stateId) => state.isStopped || stateId !== state.epoch

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
// in-flight fetches and marks the rollback in progress as one step, so the epoch
// bump can never be left out.
let beginReorg = (state: t, ~chain, ~blockNumber, ~chainManager) => {
  state.chainManager = chainManager
  state.epoch = state.epoch + 1
  state.isRollingBack = true
  state.rollbackState = ReorgDetected({chain, blockNumber})
}

let enterFindingReorgDepth = (state: t) => state.rollbackState = FindingReorgDepth

let foundReorgDepth = (state: t, ~chain, ~rollbackTargetBlockNumber) =>
  state.rollbackState = FoundReorgDepth({chain, rollbackTargetBlockNumber})

// Finish a rollback. Commits the rolled-back manager, leaves the diff ready for
// the next batch to consume and clears the in-progress flag as one step.
let completeRollback = (state: t, ~eventsProcessedDiffByChain, ~chainManager) => {
  state.rollbackState = RollbackReady({eventsProcessedDiffByChain: eventsProcessedDiffByChain})
  state.isRollingBack = false
  state.chainManager = chainManager
}

let clearRollback = (state: t) => state.rollbackState = NoRollback

// Invalidate in-flight fetches/waiters without starting a rollback, eg on the
// realtime transition where the parked waiter is bound to the pre-realtime source.
let invalidateInflight = (state: t) => state.epoch = state.epoch + 1

let applyBatchProgress = (state: t, ~batch) =>
  state.chainManager = state.chainManager->ChainManager.updateProgressedChains(~batch)

// Processing-loop mutex, kept on the in-memory store so the store can refuse to
// flush mid-batch.
let isProcessing = (state: t) => state.ctx.inMemoryStore.isProcessing
let beginProcessing = (state: t) => state.ctx.inMemoryStore.isProcessing = true
let endProcessing = (state: t) => state.ctx.inMemoryStore.isProcessing = false

let recordProcessedBatch = (state: t) =>
  state.ctx.inMemoryStore.processedBatchesCount = state.ctx.inMemoryStore.processedBatchesCount + 1
