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
  // Indexer-wide fetch buffer pool (item count), shared across all chains.
  targetBufferSize: int,
}

// The whole-indexer fetch buffer pool, independent of chain count.
let calculateTargetBufferSize = () =>
  switch Env.targetBufferSize {
  | Some(size) => size
  | None => 100_000
  }

let make = (
  ~chainStates,
  ~isInReorgThreshold,
  ~isRealtime,
  ~targetBufferSize=calculateTargetBufferSize(),
): t => {
  let crossChainState = {
    chainStates,
    chainIds: chainStates->Dict.valuesToArray->Array.map(cs => (cs->ChainState.chainConfig).id),
    isRealtime,
    isInReorgThreshold,
    targetBufferSize,
  }
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

  crossChainState.isRealtime = crossChainState.isRealtime || allChainsReady.contents
}

// --- Fetch control. ---

// Chains ordered furthest-behind first, so the shared buffer pool goes to the
// chains with the most backfill work before the rest.
let priorityOrder = (crossChainState: t) =>
  crossChainState.chainStates
  ->Dict.valuesToArray
  ->Array.toSorted((a, b) =>
    Float.compare(
      a->ChainState.fetchState->FetchState.getProgressPercentage,
      b->ChainState.fetchState->FetchState.getProgressPercentage,
    )
  )

// In-flight estimated items across every chain — the live draw against
// targetBufferSize alongside totalReadyCount, so the pool isn't re-dispatched
// while queries are still being fetched.
let totalReservedSize = (crossChainState: t) => {
  let total = ref(0.)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    total := total.contents +. cs->ChainState.pendingBudget
  }
  total.contents
}

// Furthest-behind first: order candidate queries by the chain progress % at
// their fromBlock, so the most behind ranges across all chains are admitted
// before the rest.
let compareByProgress = (a: FetchState.query, b: FetchState.query) =>
  Float.compare(a.progress, b.progress)

// Dispatch a fetch tick across the whole indexer from one shared pool of
// ~targetBufferSize ready events. Every chain proposes its candidate queries
// (each carrying an estimated response size) against the full free budget; the
// candidates are then pooled, ordered by chain progress (furthest-behind first),
// and admitted until the budget is consumed. So the budget is split per query
// across chains rather than per chain — a chain that can only use a little
// leaves the rest for the others automatically.
let checkAndFetch = async (
  crossChainState: t,
  ~dispatchChain: (~chain: ChainMap.Chain.t, ~action: FetchState.nextQuery) => promise<unit>,
) => {
  let remaining = Pervasives.max(
    0,
    crossChainState.targetBufferSize -
    crossChainState->totalReadyCount -
    crossChainState->totalReservedSize->Float.toInt,
  )

  let chainIds = crossChainState.chainIds
  let actionByChain = Dict.make()
  // Candidate queries from every chain. Each query carries its chain id and the
  // chain progress % at its fromBlock (the admission sort key), set here so the
  // pool can be ordered without a side tuple per query.
  let candidates = []
  for i in 0 to chainIds->Array.length - 1 {
    let chainId = chainIds->Array.getUnsafe(i)
    let cs = crossChainState->getChainState(chainId)
    let fetchState = cs->ChainState.fetchState
    switch fetchState->FetchState.getNextQuery(
      ~budget=remaining,
      ~chainPendingBudget=cs->ChainState.pendingBudget,
    ) {
    | (WaitingForNewBlock | NothingToQuery) as action =>
      actionByChain->Utils.Dict.setByInt(chainId, action)
    | Ready(queries) =>
      // Default to NothingToQuery; replaced below if any candidate is admitted.
      actionByChain->Utils.Dict.setByInt(chainId, FetchState.NothingToQuery)
      queries->Array.forEach(query => {
        query.chainId = chainId
        query.progress =
          fetchState->FetchState.getProgressPercentageAt(~blockNumber=query.fromBlock)
        candidates->Array.push(query)
      })
    }
  }

  candidates->Array.sort(compareByProgress)

  // Admit furthest-behind first until the budget runs out. The condition is
  // checked before each query, so as long as there's any budget left we admit
  // the next one even when its estimate alone exceeds the remainder — otherwise a
  // chain whose only query is bigger than the budget would never make progress.
  let admittedByChain = Dict.make()
  let running = ref(0.)
  let remainingF = remaining->Int.toFloat
  let idx = ref(0)
  while running.contents < remainingF && idx.contents < candidates->Array.length {
    let query = candidates->Array.getUnsafe(idx.contents)
    admittedByChain->Utils.Dict.push(query.chainId->Int.toString, query)
    running := running.contents +. query.estResponseSize
    idx := idx.contents + 1
  }
  admittedByChain->Dict.forEachWithKey((queries, chainId) => {
    actionByChain->Dict.set(chainId, FetchState.Ready(queries))
    // Mark the admitted queries in flight and reserve their size against the
    // shared budget; released as each response lands in handleQueryResult.
    crossChainState
    ->getChainState(chainId->Int.fromString->Option.getUnsafe)
    ->ChainState.startFetchingQueries(~queries)
  })

  let promises = []
  for i in 0 to chainIds->Array.length - 1 {
    let chainId = chainIds->Array.getUnsafe(i)
    switch actionByChain->Utils.Dict.dangerouslyGetByIntNonOption(chainId) {
    | Some(NothingToQuery)
    | None => ()
    | Some(action) =>
      let chain = ChainMap.Chain.makeUnsafe(~chainId)
      promises->Array.push(dispatchChain(~chain, ~action))
    }
  }
  let _ = await promises->Promise.all
}
