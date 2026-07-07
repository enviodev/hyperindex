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
  | None => 50_000
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
    total := total.contents + cs->ChainState.bufferReadyCount
  }
  total.contents
}

// --- Derived (pure). ---

let nextItemIsNone = (crossChainState: t): bool =>
  !(crossChainState.chainStates->Dict.valuesToArray->Array.some(ChainState.hasReadyItem))

let getSafeCheckpointId = (crossChainState: t) => {
  let result: ref<option<bigint>> = ref(None)

  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    switch cs->ChainState.safeCheckpointTracking {
    | None => () // Skip chains with maxReorgDepth = 0
    | Some(safeCheckpointTracking) =>
      let safeCheckpointId =
        safeCheckpointTracking->SafeCheckpointTracking.getSafeCheckpointId(
          ~sourceBlockNumber=cs->ChainState.knownHeight,
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
    ~chainsBeforeBatch=crossChainState.chainStates->Utils.Dict.mapValues(
      ChainState.toChainBeforeBatch,
    ),
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
    Float.compare(a->ChainState.getProgressPercentage, b->ChainState.getProgressPercentage)
  )

// Items reserved by in-flight queries across every chain — the live draw against
// targetBufferSize alongside totalReadyCount, so the pool isn't re-dispatched
// while queries are still being fetched.
let totalReservedSize = (crossChainState: t) => {
  let total = ref(0.)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    total := total.contents +. cs->ChainState.reservedSize
  }
  total.contents
}

// Furthest-behind first: order candidate queries by the chain progress % at
// their fromBlock, so the most behind ranges across all chains are admitted
// before the rest.
let compareByProgress = (a: FetchState.query, b: FetchState.query) =>
  Float.compare(a.progress, b.progress)

// The reach a chain gets when it has no usable frontier density yet (cold start,
// or a freshly-registered partition sitting at the frontier): probe a fixed block
// window rather than reaching blindly. Reuses the partition "too far to merge"
// threshold so the probe stays within one working cluster.
let fixedReach = FetchState.OptimizedPartitions.tooFarBlockRange

// Dispatch a fetch tick across the whole indexer from one shared pool of
// ~targetBufferSize events. Every chain proposes its candidate queries up to its
// own natural ceiling (head/endBlock/mergeBlock); the scheduler then decides how
// far past each chain's frontier to reach. From the shared budget and each warm
// chain's frontier density it picks one progress-fraction advance (aligned, so
// chains stay level for timestamp-ordered processing), turns that into a per-chain
// block cutoff, and admits only the candidates within the cutoff — partitions
// parked far ahead are skipped, since fetching them would only pile up
// unprocessable items. Each admitted query's itemsTarget is its density times the
// blocks it covers up to the cutoff, so the tick pulls in ~budget events total and
// the buffer can't overshoot no matter how large a range or how many partitions.
// Admission runs furthest-behind first, so when the budget is tight the most
// behind chains claim it first.
let checkAndFetch = async (
  crossChainState: t,
  ~dispatchChain: (~chain: ChainMap.Chain.t, ~action: FetchState.nextQuery) => promise<unit>,
) => {
  let budget = Pervasives.max(
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
  // Per-chain reach cutoff (block), keyed by chain id. Set to the fixed probe now
  // for cold chains; warm chains are filled in once the aligned advance is known.
  let cutoffByChain = Dict.make()
  // Warm chains (frontier density known) and the running Σ(density × range) that
  // sizes the shared progress advance.
  let warmChains = []
  let weightSum = ref(0.)
  for i in 0 to chainIds->Array.length - 1 {
    let chainId = chainIds->Array.getUnsafe(i)
    let cs = crossChainState->getChainState(chainId)
    switch cs->ChainState.getNextQuery {
    | (WaitingForNewBlock | NothingToQuery) as action =>
      actionByChain->Utils.Dict.setByInt(chainId, action)
    | Ready(queries) =>
      // Default to NothingToQuery; replaced below if any candidate is admitted.
      actionByChain->Utils.Dict.setByInt(chainId, FetchState.NothingToQuery)
      let frontier = cs->ChainState.frontierBlockNumber
      let range = cs->ChainState.fetchRange
      switch cs->ChainState.frontierDensity {
      | Some(density) if range > 0 =>
        weightSum := weightSum.contents +. density *. range->Int.toFloat
        warmChains->Array.push((chainId, frontier, range))->ignore
      | _ => cutoffByChain->Utils.Dict.setByInt(chainId, frontier + fixedReach)
      }
      queries->Array.forEach(query => {
        query.chainId = chainId
        query.progress = cs->ChainState.getProgressPercentageAt(~blockNumber=query.fromBlock)
        candidates->Array.push(query)
      })
    }
  }

  // Aligned advance: move every warm chain forward by the same progress fraction
  // Δp, chosen so the tick's fetched events add up to the budget. Δp × range is
  // the chain's block reach, floored at 1 (so the frontier partition is always
  // reachable) and capped at its own range.
  if budget > 0 && weightSum.contents > 0. {
    let deltaP = budget->Int.toFloat /. weightSum.contents
    warmChains->Array.forEach(((chainId, frontier, range)) => {
      let reach = Pervasives.max(
        1,
        Pervasives.min(Js.Math.round(deltaP *. range->Int.toFloat)->Float.toInt, range),
      )
      cutoffByChain->Utils.Dict.setByInt(chainId, frontier + reach)
    })
  }

  // Furthest-behind first, so the most-behind chains claim the budget first.
  candidates->Array.sort(compareByProgress)

  // Even fallback cap for admitted candidates whose partition has no density yet,
  // spread only across the near-frontier candidates that pass the reach filter.
  let eligibleCount = ref(0)
  candidates->Array.forEach(query =>
    switch cutoffByChain->Utils.Dict.dangerouslyGetByIntNonOption(query.chainId) {
    | Some(cutoff) if query.fromBlock <= cutoff => eligibleCount := eligibleCount.contents + 1
    | _ => ()
    }
  )
  let evenShare =
    eligibleCount.contents > 0
      ? Js.Math.ceil_int(budget->Int.toFloat /. eligibleCount.contents->Int.toFloat)
      : 0

  let admittedByChain = Dict.make()
  let remaining = ref(budget)
  let idx = ref(0)
  while remaining.contents > 0 && idx.contents < candidates->Array.length {
    let query = candidates->Array.getUnsafe(idx.contents)
    idx := idx.contents + 1
    switch cutoffByChain->Utils.Dict.dangerouslyGetByIntNonOption(query.chainId) {
    // Parked beyond the reach — skip this tick, it would only add stuck items.
    | Some(cutoff) if query.fromBlock <= cutoff =>
      let effectiveTo = switch query.toBlock {
      | Some(toBlock) => Pervasives.min(toBlock, cutoff)
      | None => cutoff
      }
      let span = effectiveTo - query.fromBlock + 1
      let baseTarget = switch query.density {
      | Some(density) => Js.Math.round(density *. span->Int.toFloat)->Float.toInt
      | None => evenShare
      }
      let target = Pervasives.min(remaining.contents, Pervasives.max(1, baseTarget))
      query.itemsTarget = target
      remaining := remaining.contents - target
      admittedByChain->Utils.Dict.push(query.chainId->Int.toString, query)
    | _ => ()
    }
  }
  admittedByChain->Dict.forEachWithKey((queries, chainId) => {
    let partitions = Dict.make()
    queries->Array.forEach((query: FetchState.query) =>
      partitions->Dict.set(
        query.partitionId,
        {
          "fromBlock": query.fromBlock,
          "targetBlock": query.toBlock,
          "targetEvents": query.itemsTarget,
        },
      )
    )
    Logging.trace({
      "msg": "Started querying",
      "chainId": chainId->Int.fromString->Option.getUnsafe,
      "partitions": partitions,
    })
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
