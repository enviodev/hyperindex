// Whole-indexer view over every chain's ChainState: the chain collection plus
// the run-wide flags derived from it. Owns the cross-chain reads and the
// batch/threshold transitions that touch every chain. `t` is mutated in place
// through the transitions below; the type is opaque in the interface.

type t = {
  chainStates: dict<ChainState.t>,
  // True once every chain has caught up to head/endBlock. Monotonic during a run.
  mutable isRealtime: bool,
  mutable isInReorgThreshold: bool,
  // Indexer-wide caps on concurrent data-source queries, shared across all
  // chains. The realtime budget applies once every chain is at head.
  maxBackfillConcurrency: int,
  maxRealtimeConcurrency: int,
  // Indexer-wide fetch buffer pool (item count), shared across all chains.
  targetBufferSize: int,
}

// The whole-indexer fetch buffer pool, independent of chain count.
let calculateTargetBufferSize = () =>
  switch Env.targetBufferSize {
  | Some(size) => size
  | None => 100_000
  }

// The concurrency budget in force for the current phase.
let maxConcurrency = (cm: t) =>
  cm.isRealtime ? cm.maxRealtimeConcurrency : cm.maxBackfillConcurrency

let make = (
  ~chainStates,
  ~isInReorgThreshold,
  ~isRealtime,
  ~maxBackfillConcurrency=Env.maxBackfillConcurrency,
  ~maxRealtimeConcurrency=Env.maxRealtimeConcurrency,
  ~targetBufferSize=calculateTargetBufferSize(),
): t => {
  let cm = {
    chainStates,
    isRealtime,
    isInReorgThreshold,
    maxBackfillConcurrency,
    maxRealtimeConcurrency,
    targetBufferSize,
  }
  Prometheus.IndexingMaxConcurrency.set(~maxConcurrency=cm->maxConcurrency)
  Prometheus.IndexingTargetBufferSize.set(~targetBufferSize)
  cm
}

// --- Accessors. ---

let chainStates = (cm: t) => cm.chainStates
let isRealtime = (cm: t) => cm.isRealtime
let isInReorgThreshold = (cm: t) => cm.isInReorgThreshold

// Partition queries in flight across every chain — the live draw against
// maxConcurrency.
let inFlight = (cm: t) =>
  cm.chainStates
  ->Dict.valuesToArray
  ->Array.reduce(0, (acc, cs) => acc + cs->ChainState.sourceManager->SourceManager.inFlightCount)

// Ready-to-process items across every chain — the live draw against
// targetBufferSize, which is a budget of processable events (items stuck behind
// a gap don't count toward the goal of keeping ~targetBufferSize ready).
let totalReadyCount = (cm: t) =>
  cm.chainStates
  ->Dict.valuesToArray
  ->Array.reduce(0, (acc, cs) => acc + cs->ChainState.fetchState->FetchState.bufferReadyCount)

// --- Derived (pure). ---

let nextItemIsNone = (cm: t): bool =>
  !Batch.hasReadyItem(cm.chainStates->Dict.valuesToArray->Array.map(ChainState.fetchState))

let getSafeCheckpointId = (cm: t) => {
  let result: ref<option<bigint>> = ref(None)

  cm.chainStates->Utils.Dict.forEach(cs => {
    switch cs->ChainState.safeCheckpointTracking {
    | None => () // Skip chains with maxReorgDepth = 0
    | Some(safeCheckpointTracking) => {
        let safeCheckpointId =
          safeCheckpointTracking->SafeCheckpointTracking.getSafeCheckpointId(
            ~sourceBlockNumber=(cs->ChainState.fetchState).knownHeight,
          )
        switch result.contents {
        | None => result := Some(safeCheckpointId)
        | Some(current) if safeCheckpointId < current => result := Some(safeCheckpointId)
        | _ => ()
        }
      }
    }
  })

  switch result.contents {
  | Some(id) if id > 0n => Some(id)
  | _ => None // No safe checkpoint found
  }
}

// --- Cross-chain transitions. ---

let createBatch = (
  cm: t,
  ~processedCheckpointId,
  ~batchSizeTarget: int,
  ~isRollback: bool,
): Batch.t => {
  Batch.make(
    ~isInReorgThreshold=cm.isInReorgThreshold,
    ~checkpointIdBeforeBatch=processedCheckpointId->BigInt.add(
      // Since for rollback we have a diff checkpoint id.
      // This is needed to currectly overwrite old state
      // in an append-only ClickHouse insert.
      isRollback ? 1n : 0n,
    ),
    ~chainsBeforeBatch=cm.chainStates->Utils.Dict.mapValues((cs): Batch.chainBeforeBatch => {
      fetchState: cs->ChainState.fetchState,
      progressBlockNumber: cs->ChainState.committedProgressBlockNumber,
      totalEventsProcessed: cs->ChainState.numEventsProcessed,
      sourceBlockNumber: (cs->ChainState.fetchState).knownHeight,
      reorgDetection: cs->ChainState.reorgDetection,
      chainConfig: cs->ChainState.chainConfig,
    }),
    ~batchSizeTarget,
  )
}

// Enter the reorg threshold: shrink each chain's buffer by its configured
// blockLag and flip the flag.
let enterReorgThreshold = (cm: t) => {
  Logging.info("Reorg threshold reached")
  Prometheus.ReorgThreshold.set(~isInReorgThreshold=true)

  cm.chainStates->Utils.Dict.forEach(ChainState.enterReorgThreshold)

  cm.isInReorgThreshold = true
}

// Commit each progressed chain's batch progress, then decide readiness for the
// whole indexer. A chain is marked caught up only once EVERY chain is caught up
// (reached endblock or fetched/processed to head) with no processable events
// left — so no chain flips to ready while another is still backfilling.
let applyBatchProgress = (cm: t, ~batch: Batch.t) => {
  cm.chainStates->Utils.Dict.forEach(cs => cs->ChainState.applyBatchProgress(~batch))

  let indexerCaughtUp =
    cm->nextItemIsNone &&
      cm.chainStates
      ->Dict.valuesToArray
      ->Array.every(cs => cs->ChainState.hasProcessedToEndblock || cs->ChainState.isProgressAtHead)

  let allChainsReady = ref(true)
  cm.chainStates->Utils.Dict.forEach(cs => {
    if indexerCaughtUp {
      cs->ChainState.markReady
    }
    if !(cs->ChainState.isReady) {
      allChainsReady := false
    }
  })

  if allChainsReady.contents {
    Prometheus.ProgressReady.setAllReady()
  }

  let wasRealtime = cm.isRealtime
  cm.isRealtime = cm.isRealtime || allChainsReady.contents
  if !wasRealtime && cm.isRealtime {
    // The realtime budget takes over now that every chain is at head.
    Prometheus.IndexingMaxConcurrency.set(~maxConcurrency=cm->maxConcurrency)
  }
}

// --- Fetch control. ---

// Some chain still has backfill work — its fetch frontier hasn't reached head.
let anyChainBackfilling = (cm: t) =>
  cm.chainStates->Dict.valuesToArray->Array.some(cs => !(cs->ChainState.isFetchingAtHead))

// During backfill a chain that has fetched up to its head is paused while some
// other chain is still backfilling: it yields all fetch resources to the chains
// with real work and resumes once they catch up (and the indexer goes realtime).
// Never pause when nothing is backfilling (all chains converging to head) or in
// realtime — every chain follows the head, bounded only by the shared budget.
let shouldPauseFetch = (cs: ChainState.t, ~isRealtime, ~anyChainBackfilling) =>
  !isRealtime && anyChainBackfilling && cs->ChainState.isFetchingAtHead

// Chains ordered furthest-behind first, so the shared concurrency and buffer
// pools go to the chains with the most backfill work before the rest.
let priorityOrder = (cm: t) =>
  cm.chainStates
  ->Dict.valuesToArray
  ->Array.toSorted((a, b) =>
    Float.compare(
      a->ChainState.fetchState->FetchState.getProgressPercentage,
      b->ChainState.fetchState->FetchState.getProgressPercentage,
    )
  )

// Dispatch a fetch tick across every chain in priority order, drawing from the
// shared concurrency and buffer pools. Chains are visited in turn; fetchChain
// bumps the in-flight count synchronously before it suspends, so a later chain
// sees the slots an earlier one already claimed and the budget is honored
// indexer-wide.
//
// bufferLimit is each chain's slice of the shared pool: it may grow its buffer
// into whatever the other chains leave free, so a lone backfilling chain can use
// the whole pool while head-following chains stay shallow.
let checkAndFetch = async (
  cm: t,
  ~fetchChain: (
    ~chain: ChainMap.Chain.t,
    ~concurrencyLimit: int,
    ~bufferLimit: int,
  ) => promise<unit>,
) => {
  let isRealtime = cm.isRealtime
  let maxConcurrency = cm->maxConcurrency
  let anyChainBackfilling = cm->anyChainBackfilling
  // Pool is a budget of ready-to-process items, but the cap fed to getNextQuery
  // is still a buffer position (it tracks the sorted buffer, ready items first),
  // so add this chain's own buffer size back rather than its ready count. A chain
  // with a gap therefore gets extra headroom to fetch the not-ready overhang
  // while still aiming for its share of ~targetBufferSize ready events.
  let totalReady = cm->totalReadyCount
  // Track the in-flight total as a running counter (summed once up front, then
  // adjusted by each chain's delta) instead of re-summing every chain — O(chains)
  // per tick rather than O(chains^2). fetchChain bumps the chain's count
  // synchronously, so the delta is observable right after the call.
  let inFlight = ref(cm->inFlight)
  let _ = await cm
  ->priorityOrder
  ->Array.filterMap(cs =>
    if cs->shouldPauseFetch(~isRealtime, ~anyChainBackfilling) {
      None
    } else {
      let chain = ChainMap.Chain.makeUnsafe(~chainId=(cs->ChainState.chainConfig).id)
      let sourceManager = cs->ChainState.sourceManager
      let concurrencyLimit = Pervasives.max(0, maxConcurrency - inFlight.contents)
      let bufferLimit =
        cm.targetBufferSize - (totalReady - cs->ChainState.fetchState->FetchState.bufferSize)
      let inFlightBefore = sourceManager->SourceManager.inFlightCount
      let promise = fetchChain(~chain, ~concurrencyLimit, ~bufferLimit)
      inFlight := inFlight.contents + (sourceManager->SourceManager.inFlightCount - inFlightBefore)
      Some(promise)
    }
  )
  ->Promise.all
}
