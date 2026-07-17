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
let applyBatchProgress = (crossChainState: t, ~batch: Batch.t, ~blockTimestampName: string) => {
  let chainIds = crossChainState.chainIds

  let everyChainCaughtUp = ref(true)
  for i in 0 to chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(chainIds->Array.getUnsafe(i))
    cs->ChainState.applyBatchProgress(~batch, ~blockTimestampName)
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

// Chains ordered furthest-behind first by fetch-frontier progress, so the
// shared buffer pool goes to the chains with the most fetchable backfill work
// before the rest — and the same metric that sets the alignment line also
// decides who draws budget first, so the anchor is served before any chain it
// clamps. (Batch ordering keeps its own getProgressPercentage measure.) A chain
// with no known height reads 100% here and sorts last, which is fine: it can't
// fetch until its first block lands regardless of when it's visited.
let priorityOrder = (crossChainState: t) =>
  crossChainState.chainStates
  ->Dict.valuesToArray
  ->Array.toSorted((a, b) =>
    Float.compare(a->ChainState.frontierProgress, b->ChainState.frontierProgress)
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

// Action for a chain that was handed budget but emitted no query (its budget
// went to more-behind chains, or the alignment clamp cut its range to
// nothing). A chain is genuinely idle — and correctly left undispatched —
// when it is caught up to its head/endblock, still draining in-flight
// queries, or holding ready items that batch processing will drain and
// re-schedule from. Any other chain must keep polling for new blocks instead
// of going silent: NothingToQuery isn't dispatched, and with the pool
// unsaturated nothing else guarantees a tick that would revisit it, so its
// head tracking would freeze.
let idleOrWaitAction = (cs: ChainState.t) =>
  cs->ChainState.isFetchingAtHead ||
  cs->ChainState.pendingBudget > 0. ||
  cs->ChainState.bufferReadyCount > 0
    ? FetchState.NothingToQuery
    : FetchState.WaitingForNewBlock

// Dispatch a fetch tick across the whole indexer from one shared pool of
// ~targetBufferSize ready events, as a waterfall: visit chains furthest-behind
// first, hand each the budget remaining at that point (plus its own
// already-reserved share, since a chain's pending queries aren't "spent" —
// they're this chain's), let it turn that into queries sized against its own
// chain-density-derived target block, then subtract what it actually used
// before moving to the next chain. So a chain that can only use a little
// (density too low, or already caught up) leaves the rest for the others
// automatically. Starting a new query requires at least 10% of the target pool
// to be free. A chain visited after the budget falls below that admission unit
// doesn't query this round — reservations release as responses land, so the
// next tick redistributes. Every other chain is additionally capped at the
// lowest-frontier-progress chain's progress mapped onto its own range, so no
// chain runs ahead of the chain the pool is prioritizing — including on ticks
// where that chain is mid-fetch and emits no new query. A chain with no known
// height can't anchor this line (there's no range to measure against), a chain
// caught up to its fetchable head reads 100% and so never anchors while another
// is behind, and once the whole indexer has caught up (isRealtime) the clamp is
// dropped — chains at head only trail each other by real-time block production.
let checkAndFetch = async (
  crossChainState: t,
  ~dispatchChain: (~chain: ChainMap.Chain.t, ~action: FetchState.nextQuery) => promise<unit>,
) => {
  let targetBudget = crossChainState.targetBufferSize->Int.toFloat
  let remaining = ref(
    Pervasives.max(
      0.,
      targetBudget -.
      crossChainState->totalReadyCount->Int.toFloat -.
      crossChainState->totalReservedSize,
    ),
  )

  // New fetch work is admitted in units of 10% of the target pool. Waiting
  // below this floor avoids spending the last few free items on undersized
  // queries; response and batch completion schedule another tick after they
  // release enough budget.
  let minimumAdmissionBudget = targetBudget *. 0.1

  // A chain with no density signal probes blind, so it only gets a bounded
  // slice of the pool — one unknown chain shouldn't hold the whole budget
  // while it takes its first measurements. Its probe is one admission unit.
  let coldChainBudget = minimumAdmissionBudget

  // Chunk reservations get headroom over the density estimate so a
  // denser-than-expected range doesn't truncate at the server cap; realtime
  // gets more since a forced catch-up query there costs a head-poll roundtrip.
  let chunkItemsMultiplier = crossChainState.isRealtime ? 3. : 1.5

  // Server-cap floor for bounded queries: their block range is already the
  // hard bound on the response, so a low density estimate shrinking the cap
  // below this only buys self-truncated responses. Splitting the target pool
  // across a chain's concurrency slots keeps the worst case — every in-flight
  // bounded query returning a full floored response at once — at ~one buffer
  // target.
  let itemsTargetFloor = crossChainState.targetBufferSize / FetchState.maxChainConcurrency

  let prioritizedChainStates = crossChainState->priorityOrder

  // Alignment anchor: the first known-height chain in priority order — which,
  // since that order sorts by frontier progress, is the chain furthest behind
  // by the very metric the clamp maps other chains against. Anchoring on the
  // frontier (not on the target of whichever chain happens to query this tick)
  // keeps the line in place while the anchor's queries are still in flight. A
  // chain caught up to its fetchable head reads 100% and sorts past any behind
  // chain, so it never anchors while another chain is behind.
  let alignment = crossChainState.isRealtime
    ? None
    : prioritizedChainStates
      ->Array.find(cs => cs->ChainState.knownHeight != 0)
      ->Option.map(cs => ((cs->ChainState.chainConfig).id, cs->ChainState.frontierProgress))

  let actionByChain = Dict.make()
  prioritizedChainStates->Array.forEach(cs => {
    let chainId = (cs->ChainState.chainConfig).id
    if cs->ChainState.knownHeight == 0 {
      // No height yet — there's nothing to size a query against, only height
      // tracking to start. Checked before the admission floor so a chain that
      // hasn't found its first block yet keeps polling even while other chains
      // hold the whole pool. (The general can't-fetch-yet rule, including
      // blockLag, lives in FetchState.getNextQuery — this branch only
      // short-circuits the unambiguous no-height case.)
      actionByChain->Utils.Dict.setByInt(chainId, FetchState.WaitingForNewBlock)
    } else if remaining.contents < minimumAdmissionBudget {
      // More than 90% of the target pool is ready or reserved. Don't admit new
      // queries until a full admission unit becomes free. No wake-up poll is
      // needed: a saturated pool means some chain holds ready items or
      // in-flight reservations, so a batch completion or landing response is
      // guaranteed to schedule another tick that revisits this chain.
      actionByChain->Utils.Dict.setByInt(chainId, FetchState.NothingToQuery)
    } else {
      let isCold = cs->ChainState.effectiveDensity === None
      let chainTargetItems =
        (isCold ? Pervasives.min(remaining.contents, coldChainBudget) : remaining.contents) +.
        cs->ChainState.pendingBudget
      let maxTargetBlock = switch alignment {
      // 5% margin past the anchor's line: chains whose progress tracks the
      // anchor closely would otherwise flap in and out of the clamp on every
      // small frontier move, stalling their pipeline every other tick.
      | Some((anchorChainId, progress)) if anchorChainId !== chainId =>
        Some(cs->ChainState.blockAtProgress(~progress=progress +. 0.05))
      | _ => None
      }
      switch cs->ChainState.getNextQuery(
        ~chainTargetItems,
        ~chunkItemsMultiplier,
        ~itemsTargetFloor,
        ~maxTargetBlock?,
      ) {
      | WaitingForNewBlock as action => actionByChain->Utils.Dict.setByInt(chainId, action)
      | NothingToQuery =>
        // A chain below its head can emit no query when its budget went to
        // more-behind chains or the cross-chain alignment clamped its range to
        // nothing — idleOrWaitAction keeps it polling for new blocks.
        actionByChain->Utils.Dict.setByInt(chainId, idleOrWaitAction(cs))
      | Ready(queries) => {
          let consumed =
            queries->Array.reduce(0., (acc, query: FetchState.query) =>
              acc +. query.itemsEst->Int.toFloat
            )

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
            "chainId": chainId,
            "partitions": partitions,
          })

          actionByChain->Utils.Dict.setByInt(chainId, FetchState.Ready(queries))
          // Mark the queries in flight and reserve their size against the
          // shared budget; released as each response lands in
          // handleQueryResult.
          cs->ChainState.startFetchingQueries(~queries)
          remaining := Pervasives.max(0., remaining.contents -. consumed)
        }
      }
    }
  })

  let promises = []
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let chainId = crossChainState.chainIds->Array.getUnsafe(i)
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
