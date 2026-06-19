// Whole-indexer view over every chain's ChainState: the chain collection plus
// the run-wide flags derived from it. Owns the cross-chain reads and the
// batch/threshold transitions that touch every chain. `t` is mutated in place
// through the transitions below; the type is opaque in the interface.

type t = {
  chainStates: dict<ChainState.t>,
  // Chain ids in a stable order, so the cross-chain loops iterate the chains
  // without allocating a values array on every tick.
  chainIds: array<int>,
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
let maxConcurrency = (crossChainState: t) =>
  crossChainState.isRealtime
    ? crossChainState.maxRealtimeConcurrency
    : crossChainState.maxBackfillConcurrency

let make = (
  ~chainStates,
  ~isInReorgThreshold,
  ~isRealtime,
  ~maxBackfillConcurrency=Env.maxBackfillConcurrency,
  ~maxRealtimeConcurrency=Env.maxRealtimeConcurrency,
  ~targetBufferSize=calculateTargetBufferSize(),
): t => {
  let crossChainState = {
    chainStates,
    chainIds: chainStates->Dict.valuesToArray->Array.map(cs => (cs->ChainState.chainConfig).id),
    isRealtime,
    isInReorgThreshold,
    maxBackfillConcurrency,
    maxRealtimeConcurrency,
    targetBufferSize,
  }
  Prometheus.IndexingMaxConcurrency.set(~maxConcurrency=crossChainState->maxConcurrency)
  Prometheus.IndexingTargetBufferSize.set(~targetBufferSize)
  crossChainState
}

// Resolve a chain's state by id. The id always comes from `chainIds`, which is
// derived from `chainStates`, so the entry is guaranteed present.
let getChainState = (crossChainState: t, chainId) =>
  crossChainState.chainStates->Utils.Dict.dangerouslyGetByIntNonOption(chainId)->Option.getUnsafe

// --- Accessors. ---

let chainStates = (crossChainState: t) => crossChainState.chainStates
let isRealtime = (crossChainState: t) => crossChainState.isRealtime
let isInReorgThreshold = (crossChainState: t) => crossChainState.isInReorgThreshold

// Partition queries in flight across every chain — the live draw against
// maxConcurrency.
let inFlight = (crossChainState: t) => {
  let total = ref(0)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    total := total.contents + cs->ChainState.sourceManager->SourceManager.inFlightCount
  }
  total.contents
}

// Ready-to-process items across every chain — the live draw against
// targetBufferSize, which is a budget of processable events (items stuck behind
// a gap don't count toward the goal of keeping ~targetBufferSize ready).
let totalReadyCount = (crossChainState: t) => {
  let total = ref(0)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    total := total.contents + cs->ChainState.fetchState->FetchState.bufferReadyCount
  }
  total.contents
}

// --- Derived (pure). ---

let nextItemIsNone = (crossChainState: t): bool =>
  !Batch.hasReadyItem(
    crossChainState.chainStates->Dict.valuesToArray->Array.map(ChainState.fetchState),
  )

let getSafeCheckpointId = (crossChainState: t) => {
  let result: ref<option<bigint>> = ref(None)

  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    switch cs->ChainState.safeCheckpointTracking {
    | None => () // Skip chains with maxReorgDepth = 0
    | Some(safeCheckpointTracking) =>
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

  switch result.contents {
  | Some(id) if id > 0n => Some(id)
  | _ => None // No safe checkpoint found
  }
}

// --- Cross-chain transitions. ---

let createBatch = (
  crossChainState: t,
  ~processedCheckpointId,
  ~batchSizeTarget: int,
  ~isRollback: bool,
): Batch.t => {
  Batch.make(
    ~isInReorgThreshold=crossChainState.isInReorgThreshold,
    ~checkpointIdBeforeBatch=processedCheckpointId->BigInt.add(
      // Since for rollback we have a diff checkpoint id.
      // This is needed to currectly overwrite old state
      // in an append-only ClickHouse insert.
      isRollback ? 1n : 0n,
    ),
    ~chainsBeforeBatch=crossChainState.chainStates->Utils.Dict.mapValues((
      cs
    ): Batch.chainBeforeBatch => {
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
let enterReorgThreshold = (crossChainState: t) => {
  Logging.info("Reorg threshold reached")
  Prometheus.ReorgThreshold.set(~isInReorgThreshold=true)

  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    crossChainState
    ->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    ->ChainState.enterReorgThreshold
  }

  crossChainState.isInReorgThreshold = true
}

// Commit each progressed chain's batch progress, then decide readiness for the
// whole indexer. A chain is marked caught up only once EVERY chain is caught up
// (reached endblock or fetched/processed to head) with no processable events
// left — so no chain flips to ready while another is still backfilling.
let applyBatchProgress = (crossChainState: t, ~batch: Batch.t) => {
  let chainIds = crossChainState.chainIds

  let everyChainCaughtUp = ref(true)
  for i in 0 to chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(chainIds->Array.getUnsafe(i))
    cs->ChainState.applyBatchProgress(~batch)
    if !(cs->ChainState.hasProcessedToEndblock || cs->ChainState.isProgressAtHead) {
      everyChainCaughtUp := false
    }
  }

  let indexerCaughtUp = crossChainState->nextItemIsNone && everyChainCaughtUp.contents

  let allChainsReady = ref(true)
  for i in 0 to chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(chainIds->Array.getUnsafe(i))
    if indexerCaughtUp {
      cs->ChainState.markReady
    }
    if !(cs->ChainState.isReady) {
      allChainsReady := false
    }
  }

  if allChainsReady.contents {
    Prometheus.ProgressReady.setAllReady()
  }

  let wasRealtime = crossChainState.isRealtime
  crossChainState.isRealtime = crossChainState.isRealtime || allChainsReady.contents
  if !wasRealtime && crossChainState.isRealtime {
    // The realtime budget takes over now that every chain is at head.
    Prometheus.IndexingMaxConcurrency.set(~maxConcurrency=crossChainState->maxConcurrency)
  }
}

// --- Fetch control. ---

// Chains ordered furthest-behind first, so the shared concurrency and buffer
// pools go to the chains with the most backfill work before the rest.
let priorityOrder = (crossChainState: t) =>
  crossChainState.chainStates
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
  crossChainState: t,
  ~fetchChain: (
    ~chain: ChainMap.Chain.t,
    ~concurrencyLimit: int,
    ~bufferLimit: int,
  ) => promise<unit>,
) => {
  let maxConcurrency = crossChainState->maxConcurrency
  // Pool is a budget of ready-to-process items, but the cap fed to getNextQuery
  // is still a buffer position (it tracks the sorted buffer, ready items first),
  // so add this chain's own buffer size back rather than its ready count. A chain
  // with a gap therefore gets extra headroom to fetch the not-ready overhang
  // while still aiming for its share of ~targetBufferSize ready events.
  let totalReady = crossChainState->totalReadyCount
  // Track the in-flight total as a running counter (summed once up front, then
  // adjusted by each chain's delta) instead of re-summing every chain — O(chains)
  // per tick rather than O(chains^2). fetchChain bumps the chain's count
  // synchronously, so the delta is observable right after the call.
  let inFlight = ref(crossChainState->inFlight)
  let priorityOrdered = crossChainState->priorityOrder
  let promises = []
  for i in 0 to priorityOrdered->Array.length - 1 {
    let cs = priorityOrdered->Array.getUnsafe(i)
    let chain = ChainMap.Chain.makeUnsafe(~chainId=(cs->ChainState.chainConfig).id)
    let sourceManager = cs->ChainState.sourceManager
    let concurrencyLimit = Pervasives.max(0, maxConcurrency - inFlight.contents)
    let bufferLimit =
      crossChainState.targetBufferSize -
      (totalReady -
      cs->ChainState.fetchState->FetchState.bufferSize)
    let inFlightBefore = sourceManager->SourceManager.inFlightCount
    promises->Array.push(fetchChain(~chain, ~concurrencyLimit, ~bufferLimit))
    inFlight := inFlight.contents + (sourceManager->SourceManager.inFlightCount - inFlightBefore)
  }
  let _ = await promises->Promise.all
}
