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
    total := total.contents + cs->ChainState.bufferReadyCount
  }
  total.contents
}

// All buffered items across every chain, ready or stuck — the memory footprint
// the prune high-water mark is checked against.
let totalBufferSize = (crossChainState: t) => {
  let total = ref(0)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    total := total.contents + cs->ChainState.bufferSize
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

// One hysteresis band governs the prune/hold-back cycle, always measured
// against the whole buffer (ready and stuck): prune once it exceeds the
// high-water mark, drop down to the low-water mark, and hold pruned ranges
// back until it drains to targetBufferSize. The cycle is only correct while
// targetBufferSize < low-water < high-water — releasing pruned ranges any
// earlier would refetch what the prune just dropped.
let pruneHighWaterMark = (crossChainState: t) => crossChainState.targetBufferSize * 3
let pruneLowWaterMark = (crossChainState: t) => crossChainState.targetBufferSize * 3 / 2

// Removing the up-front block cap lets queries run to the head, so fetched-ahead
// items accumulate as stuck buffer while a lagging partition holds the frontier.
// This reclaims that memory reactively: once the indexer-wide buffer crosses the
// high-water mark, drop the highest-progress% (closest-to-head) items across all
// chains back down to the low-water mark and roll back the partitions that
// fetched them. Prune only during backfill — near the head blockLag keeps the
// buffer below the reorg window and there is nothing far-ahead to reclaim.
// Returns how many items were freed.
let maybePrune = (crossChainState: t, ~totalBufferSize) =>
  if (
    !crossChainState.isInReorgThreshold &&
    totalBufferSize > crossChainState->pruneHighWaterMark
  ) {
    let chainIds = crossChainState.chainIds
    let need = totalBufferSize - crossChainState->pruneLowWaterMark

    // Per-chain (target, freed) at the given progress threshold, in chainIds
    // order, plus the summed freed count. The sum is non-increasing in the
    // threshold (higher threshold = higher per-chain target = fewer items
    // dropped).
    let pruneTargetsAt = progressThreshold => {
      let freed = ref(0)
      let targets = []
      for i in 0 to chainIds->Array.length - 1 {
        let chainTarget =
          crossChainState
          ->getChainState(chainIds->Array.getUnsafe(i))
          ->ChainState.getPruneTarget(~progressThreshold)
        targets->Array.push(chainTarget)
        let (_, chainFreed) = chainTarget
        freed := freed.contents + chainFreed
      }
      (targets, freed.contents)
    }

    // Threshold 0 drops every stuck item — the most any prune can free. When
    // even that is nothing (e.g. the buffer is over the mark but full of ready
    // items), skip: quiescing in-flight fetches here would discard them every
    // tick without making room, stalling progress.
    let (targetsAtZero, freedAtZero) = pruneTargetsAt(0.)
    if freedAtZero > 0 {
      // Largest progress threshold that still frees `need` items, so we drop
      // only the closest-to-head items across all chains; the per-chain targets
      // from the winning evaluation are reused for the prune below. If even
      // threshold 0 can't reach `need`, settle there and free what we can.
      // 30 bisections resolve the threshold to 2^-30 — below one block even on
      // a billion-block chain.
      let best = ref((targetsAtZero, freedAtZero))
      if freedAtZero >= need {
        let lo = ref(0.)
        let hi = ref(1.)
        for _ in 0 to 29 {
          let mid = (lo.contents +. hi.contents) /. 2.
          let (targets, freed) = pruneTargetsAt(mid)
          if freed >= need {
            lo := mid
            best := (targets, freed)
          } else {
            hi := mid
          }
        }
      }
      let (targets, _) = best.contents

      // Only the chains that actually free something are touched: pruneBuffer's
      // rollback drops their in-flight queries above the target (late responses
      // are discarded by the still-pending check), while every other chain's
      // in-flight work — including the lagging frontier query the prune is
      // waiting on — keeps running.
      let totalFreed = ref(0)
      for i in 0 to chainIds->Array.length - 1 {
        let cs = crossChainState->getChainState(chainIds->Array.getUnsafe(i))
        let (target, freed) = targets->Array.getUnsafe(i)
        if freed > 0 {
          cs->ChainState.pruneBuffer(~targetBlockNumber=target)
          totalFreed := totalFreed.contents + freed
        }
      }

      Logging.trace({
        "msg": "Pruned stale fetch buffer above the processing frontier",
        "bufferSize": totalBufferSize,
        "freed": totalFreed.contents,
      })
      Prometheus.IndexingBufferPrune.increment(~freed=totalFreed.contents)
      totalFreed.contents
    } else {
      0
    }
  } else {
    0
  }

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
  let totalBufferSize = crossChainState->totalBufferSize
  let freed = crossChainState->maybePrune(~totalBufferSize)

  let remaining = Pervasives.max(
    0,
    crossChainState.targetBufferSize -
    crossChainState->totalReadyCount -
    crossChainState->totalReservedSize->Float.toInt,
  )

  // A pruned range is not re-admitted while the whole buffer still holds more
  // than targetBufferSize items — otherwise the tick right after a prune would
  // refetch exactly what it dropped, since stuck items count toward the prune
  // trigger but not toward `remaining`. Once the buffer drains back to the
  // target, processing has caught up and the prune targets are cleared.
  let bufferAboveTarget = totalBufferSize - freed > crossChainState.targetBufferSize

  let chainIds = crossChainState.chainIds
  let actionByChain = Dict.make()
  // Candidate queries from every chain. Each query carries its chain id and the
  // chain progress % at its fromBlock (the admission sort key), set here so the
  // pool can be ordered without a side tuple per query.
  let candidates = []
  for i in 0 to chainIds->Array.length - 1 {
    let chainId = chainIds->Array.getUnsafe(i)
    let cs = crossChainState->getChainState(chainId)
    if !bufferAboveTarget {
      cs->ChainState.clearPruneTarget
    }
    switch cs->ChainState.getNextQuery(~hasBudget=remaining > 0) {
    | (WaitingForNewBlock | NothingToQuery) as action =>
      actionByChain->Utils.Dict.setByInt(chainId, action)
    | Ready(queries) =>
      // Default to NothingToQuery; replaced below if any candidate is admitted.
      actionByChain->Utils.Dict.setByInt(chainId, FetchState.NothingToQuery)
      let pruneCeiling = cs->ChainState.lastPruneTarget
      queries->Array.forEach(query => {
        let isHeldBackPrunedRange = switch pruneCeiling {
        | Some(ceiling) => query.fromBlock > ceiling
        | None => false
        }
        if !isHeldBackPrunedRange {
          query.chainId = chainId
          query.progress = cs->ChainState.getProgressPercentageAt(~blockNumber=query.fromBlock)
          candidates->Array.push(query)
        }
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
    let partitions = Dict.make()
    queries->Array.forEach((query: FetchState.query) =>
      partitions->Dict.set(
        query.partitionId,
        {
          "fromBlock": query.fromBlock,
          "targetBlock": query.toBlock,
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
