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

// Total buffered items across every chain (ready plus stuck) — the live draw,
// alongside the total reservation, against the total-buffer limit.
let totalBufferSize = (crossChainState: t) => {
  let total = ref(0)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    total := total.contents + cs->ChainState.bufferSize
  }
  total.contents
}

// Items reserved by in-flight gap-closers across every chain, drawn against the
// ready target so stuck prefetch can't shrink the frontier-advancing budget.
let totalReservedReady = (crossChainState: t) => {
  let total = ref(0.)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    total := total.contents +. cs->ChainState.reservedReadySize
  }
  total.contents
}

// Items reserved by every in-flight query across every chain, drawn against the
// total-buffer limit so the pool isn't re-dispatched while queries are in flight.
let totalReservedTotal = (crossChainState: t) => {
  let total = ref(0.)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    total := total.contents +. cs->ChainState.reservedTotalSize
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

// A candidate whose fromBlock is within this of the chain frontier is a
// gap-closer (fetching it advances the ready frontier); beyond it, a prefetch
// (its items stay stuck until the frontier reaches it). Same width as the
// working cluster.
let gapCloserWindow = FetchState.OptimizedPartitions.tooFarBlockRange

// Blocks a query covers within `reach` from its own fromBlock: a bounded
// chunk/merge tail keeps its own toBlock, an open-ended tail is capped at reach.
let querySpan = (query: FetchState.query, ~reach) =>
  switch query.toBlock {
  | Some(toBlock) => Pervasives.min(toBlock - query.fromBlock + 1, reach)
  | None => reach
  }

// Dispatch a fetch tick across the whole indexer against two budgets.
//
// The ready budget keeps advancing the frontier until there are ~targetBufferSize
// *ready* items. Stuck items don't count against it, so a buffer full of items
// waiting behind a gap can never stall the gap-closing that would make them ready.
// The prefetch budget is the room left before *total* buffered items reach the
// limit; it bounds how far partitions parked ahead of the frontier may run, so the
// stuck pile can't balloon.
//
// Every chain proposes candidates up to its natural ceiling. From the ready budget
// and each warm chain's frontier density the scheduler picks one aligned
// progress-fraction advance (so chains stay level for timestamp-ordered
// processing) and turns it into a per-chain block reach. Each candidate is a
// gap-closer (near the frontier) or a prefetch (parked ahead); its itemsTarget is
// its density times the blocks it covers within the reach, and it draws from the
// matching budget. Admission runs furthest-behind first, so the most behind chains
// claim the budgets first.
let checkAndFetch = async (
  crossChainState: t,
  ~dispatchChain: (~chain: ChainMap.Chain.t, ~action: FetchState.nextQuery) => promise<unit>,
) => {
  let target = crossChainState.targetBufferSize
  let totalReady = crossChainState->totalReadyCount
  let readyBudget = Pervasives.max(
    0,
    target - totalReady - crossChainState->totalReservedReady->Float.toInt,
  )
  // Stuck = total buffered minus ready (landed) and reserved-total minus
  // reserved-ready (in flight). Allow up to `target` stuck items ahead, so total
  // buffered settles around ~2×target. It can transiently exceed that: a
  // gap-closer for a cluster partition that isn't the current minimum lands above
  // the frontier (stuck) but is charged to the ready budget, not this one — that
  // overshoot is bounded by the cluster width and drains as the minimum advances.
  // Independent of the ready budget on purpose: prefetch keeps warming partitions
  // parked ahead even while the indexer is processing-bound, so a run of in-flight
  // gap-closers can't starve it.
  let prefetchBudget = Pervasives.max(
    0,
    target -
    (crossChainState->totalBufferSize - totalReady) -
    (crossChainState->totalReservedTotal->Float.toInt -
    crossChainState->totalReservedReady->Float.toInt),
  )

  let chainIds = crossChainState.chainIds
  let actionByChain = Dict.make()
  let candidates = []
  // Per-chain frontier and reach (block window) for each budget class, keyed by
  // chain id. Prefetch gets its own reach so it isn't throttled by the ready
  // budget or by in-flight gap-closer reservations.
  let frontierByChain = Dict.make()
  let gapReachByChain = Dict.make()
  let prefetchReachByChain = Dict.make()
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
      let range = cs->ChainState.fetchRange
      frontierByChain->Utils.Dict.setByInt(chainId, cs->ChainState.frontierBlockNumber)
      switch cs->ChainState.frontierDensity {
      | Some(density) if range > 0 =>
        weightSum := weightSum.contents +. density *. range->Int.toFloat
        warmChains->Array.push((chainId, range))->ignore
      | _ =>
        gapReachByChain->Utils.Dict.setByInt(chainId, fixedReach)
        prefetchReachByChain->Utils.Dict.setByInt(chainId, fixedReach)
      }
      queries->Array.forEach(query => {
        query.chainId = chainId
        query.progress = cs->ChainState.getProgressPercentageAt(~blockNumber=query.fromBlock)
        candidates->Array.push(query)
      })
    }
  }

  // Aligned advance: each budget class moves every warm chain forward by the same
  // progress fraction, sized so the tick's queries in that class add up to its
  // budget. Reach = Δp × range, floored at 1 and capped at the chain's range. A
  // budget of 0 means that class fetches nothing (reach 0). An all-empty frontier
  // (weightSum 0) reaches to the ceiling to skip the empty region fast.
  let computeReach = (budget, range) =>
    if budget <= 0 {
      0
    } else if weightSum.contents <= 0. {
      range
    } else {
      let deltaP = budget->Int.toFloat /. weightSum.contents
      Pervasives.max(
        1,
        Pervasives.min(Math.round(deltaP *. range->Int.toFloat)->Float.toInt, range),
      )
    }
  warmChains->Array.forEach(((chainId, range)) => {
    gapReachByChain->Utils.Dict.setByInt(chainId, computeReach(readyBudget, range))
    prefetchReachByChain->Utils.Dict.setByInt(chainId, computeReach(prefetchBudget, range))
  })

  // Furthest-behind first, so the most-behind chains claim the budgets first.
  candidates->Array.sort(compareByProgress)

  // Even fallback cap for admitted candidates whose partition has no density yet,
  // split within each budget class across the density-less candidates in it.
  let gapDensityLess = ref(0)
  let prefetchDensityLess = ref(0)
  candidates->Array.forEach(query =>
    if query.density->Option.isNone {
      let frontier =
        frontierByChain->Utils.Dict.dangerouslyGetByIntNonOption(query.chainId)->Option.getOr(0)
      if query.fromBlock <= frontier + gapCloserWindow {
        gapDensityLess := gapDensityLess.contents + 1
      } else {
        prefetchDensityLess := prefetchDensityLess.contents + 1
      }
    }
  )
  let evenShare = (budget, count) =>
    count > 0 ? Js.Math.ceil_int(budget->Int.toFloat /. count->Int.toFloat) : 0
  let gapEvenShare = evenShare(readyBudget, gapDensityLess.contents)
  let prefetchEvenShare = evenShare(prefetchBudget, prefetchDensityLess.contents)

  let admittedByChain = Dict.make()
  let readyRemaining = ref(readyBudget)
  let prefetchRemaining = ref(prefetchBudget)
  let idx = ref(0)
  while (
    idx.contents < candidates->Array.length &&
      (readyRemaining.contents > 0 || prefetchRemaining.contents > 0)
  ) {
    let query = candidates->Array.getUnsafe(idx.contents)
    idx := idx.contents + 1
    let frontier =
      frontierByChain->Utils.Dict.dangerouslyGetByIntNonOption(query.chainId)->Option.getOr(0)
    let isGapCloser = query.fromBlock <= frontier + gapCloserWindow
    let reach =
      (isGapCloser ? gapReachByChain : prefetchReachByChain)
      ->Utils.Dict.dangerouslyGetByIntNonOption(query.chainId)
      ->Option.getOr(0)
    let span = querySpan(query, ~reach)
    if span > 0 {
      let remaining = isGapCloser ? readyRemaining : prefetchRemaining
      if remaining.contents > 0 {
        let baseTarget = switch query.density {
        | Some(density) => Math.round(density *. span->Int.toFloat)->Float.toInt
        | None => isGapCloser ? gapEvenShare : prefetchEvenShare
        }
        let admitted = Pervasives.min(remaining.contents, Pervasives.max(1, baseTarget))
        query.itemsTarget = admitted
        query.isPrefetch = !isGapCloser
        remaining := remaining.contents - admitted
        admittedByChain->Utils.Dict.push(query.chainId->Int.toString, query)
      }
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
