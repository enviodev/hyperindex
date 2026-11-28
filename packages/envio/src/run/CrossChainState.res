// Whole-indexer view over every chain's ChainState: the chain collection plus
// the run-wide flags derived from it. Owns the cross-chain reads and the
// batch/threshold transitions that touch every chain. `t` is mutated in place
// through the transitions below; the type is opaque in the interface.

type t = {
  chainStates: dict<ChainState.t>,
  indexingPlan: IndexingPlan.t,
  // Chain ids in a stable order, so the cross-chain loops iterate the chains
  // without allocating a values array on every tick.
  chainIds: array<ChainId.t>,
  // True once every chain this process drives has caught up to head/endBlock and
  // the indexes they owe are committed. Monotonic during a run.
  mutable isRealtime: bool,
  // True once those chains have caught up and there's nothing left to process,
  // but before the deferred schema indexes and `ready_at` are committed. The gap
  // between this and `isRealtime` is the FinalizingIndexes phase.
  mutable isCaughtUp: bool,
  // Indexer-wide fetch buffer pool (item count), shared across all chains.
  targetBufferSize: int,
  // Set on a process driving part of a split run: the chains it drives may be
  // at the head while chains in another process are still backfilling, and an
  // indexer switches to realtime as a whole or not at all. Cleared by the
  // supervisor once every chain in the run has arrived.
  mutable holdRealtime: bool,
}

let make = (~chainStates, ~indexingPlan, ~isRealtime, ~targetBufferSize, ~holdRealtime): t => {
  {
    chainStates,
    indexingPlan,
    chainIds: chainStates->Dict.valuesToArray->Array.map(cs => (cs->ChainState.chainConfig).id),
    isRealtime,
    isCaughtUp: isRealtime,
    targetBufferSize,
    holdRealtime,
  }
}

// The supervisor's go-ahead: every chain in the run has reached the head, so
// this process may make the transitions it has been holding back.
let releaseRealtime = (crossChainState: t) => crossChainState.holdRealtime = false

let isHoldingRealtime = (crossChainState: t) => crossChainState.holdRealtime

// Whether this process has got as far as it can without the run's leave. What a
// supervisor reads to decide that a split run may go realtime as one.
//
// Three ways to have arrived, because a chain can be as far along as it can get
// in three different states. Its chains have caught up; or it resumed already
// realtime; or every chain is waiting to enter the reorg threshold, which is as
// far as one can fetch while the pre-threshold lag holds it at the safe block —
// entering the threshold is what lifts that lag, so a run held until its chains
// reached the head would be holding back the transition that gets them there.
//
// The process's own conclusion rather than a reading a supervisor reassembles:
// a chain committed at what was the head and resumed once the head had moved on
// has arrived, and no live reading of it can say so — which is the same reason
// `markCaughtUpOnResume` decides before any source request.
let hasArrivedAtHead = (crossChainState: t) =>
  crossChainState.isCaughtUp ||
  crossChainState.isRealtime || {
    let chainStates = crossChainState.chainStates->Dict.valuesToArray
    chainStates->Utils.Array.notEmpty &&
      chainStates->Array.every(ChainState.isReadyToEnterReorgThreshold)
  }

// Resolve a chain's state by id. The id always comes from `chainIds`, which is
// derived from `chainStates`, so the entry is guaranteed present.
let getChainState = (crossChainState: t, chainId) =>
  crossChainState.chainStates->ChainId.Dict.dangerouslyGetNonOption(chainId)->Option.getUnsafe

// --- Accessors. ---

let chainStates = (crossChainState: t) => crossChainState.chainStates
let isRealtime = (crossChainState: t) => crossChainState.isRealtime
let chainIds = (crossChainState: t) => crossChainState.chainIds
let isCaughtUp = (crossChainState: t) => crossChainState.isCaughtUp
// Chains enter the threshold together. It is the run-wide reading; what a
// write keeps is decided per chain.
let isInReorgThreshold = (crossChainState: t) => {
  let chainStates = crossChainState.chainStates->Dict.valuesToArray
  chainStates->Utils.Array.notEmpty && chainStates->Array.every(ChainState.isInReorgThreshold)
}
let targetBufferSize = (crossChainState: t) => crossChainState.targetBufferSize

// Whether each chain's writes still need history, keyed by chain id — what the
// history policy is built from.
let shouldSaveHistory = (crossChainState: t) =>
  crossChainState.chainStates->Utils.Dict.mapValues(ChainState.shouldSaveHistory)

// --- Derived (pure). ---

let nextItemIsNone = (crossChainState: t): bool =>
  !(crossChainState.chainStates->Dict.valuesToArray->Array.some(ChainState.hasReadyItem))

// Each chain's safe checkpoint: the last one a reorg on that chain can no longer
// reach, or None while it has nothing safe yet. A chain that can't be rolled
// back (maxReorgDepth = 0) tracks none, and everything committed is safe from
// it: under one shared sequence that is the run's highest id, not the chain's
// own — an idle chain's would hold every other chain's prune back.
let getSafeCheckpointIdByChain = (
  crossChainState: t,
  ~sequence: CheckpointSequence.t,
  ~committedFrontier,
) =>
  crossChainState.chainIds->Array.map(chainId => {
    let cs = crossChainState->getChainState(chainId)
    (
      chainId,
      switch cs->ChainState.safeCheckpointTracking {
      | None => Some(sequence->CheckpointSequence.position(committedFrontier, ~chainId))
      | Some(tracking) =>
        tracking->SafeCheckpointTracking.getSafeCheckpointId(
          ~sourceBlockNumber=cs->ChainState.knownHeight,
        )
      },
    )
  })

// --- Cross-chain transitions. ---

let createBatch = (
  crossChainState: t,
  ~config: Config.t,
  ~frontier,
  ~batchSizeTarget: int,
): promise<Batch.t> => {
  Batch.make(
    ~sequence=config.checkpointSequence,
    ~history=config->HistoryPolicy.decide(~shouldSaveHistory=crossChainState->shouldSaveHistory),
    ~frontier,
    ~chainsBeforeBatch=crossChainState.chainStates->Utils.Dict.mapValues(
      ChainState.toChainBeforeBatch(~isRealtime=crossChainState.isRealtime, ...),
    ),
    ~batchSizeTarget,
  )
}

// Builds ahead the items of the chain the next batch starts with, for the
// whole target, while the current batch runs.
let prebuildNextBatch = (crossChainState: t, ~batchSizeTarget) =>
  switch crossChainState.chainStates
  ->Dict.valuesToArray
  ->Batch.sortForBatch(
    ~bufferOf=ChainState.chainBuffer,
    ~readyThroughBlockOf=ChainState.readyThroughBlock,
    ~processingBlockNumberOf=ChainState.processingBlockNumber,
    ~progressPercentageOf=ChainState.progressPercentage,
    ~batchSizeTarget,
  )
  ->Array.get(0) {
  | Some(chainState) => chainState->ChainState.prebuildItems(~targetItems=batchSizeTarget)
  | None => ()
  }

// Enter the reorg threshold: shrink each chain's buffer by its configured
// blockLag and flip the flag.
// Whether every chain this process drives has buffered close enough to the head
// to enter the threshold together — and, in a split run, whether the rest of the
// run has too. Chains enter it as one indexer, so one chain still backfilling
// holds the others back whatever process it runs in.
let isReadyToEnterReorgThreshold = (crossChainState: t, ~batch) =>
  !crossChainState.holdRealtime &&
  crossChainState.chainStates
  ->Dict.valuesToArray
  ->Array.every(cs => cs->ChainState.isReadyToEnterReorgThresholdAfterBatch(~batch))

// Said by each chain rather than once for the indexer: what crossing changes
// is a chain's own, and the chains of a split run cross in processes that can
// only speak for the ones they drive.
let enterReorgThreshold = (crossChainState: t) => {
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    // A chain whose end block sits below these blocks says nothing: crossing
    // gives it nothing more to index, and it will never reach one of them.
    let liftsCeiling = cs->ChainState.reorgThresholdLiftsCeiling
    cs->ChainState.enterReorgThreshold
    if liftsCeiling {
      cs->ChainState.logger->Logger.info(ChainState.reorgThresholdEntryMessage)
    }
  }
}

// Commit each progressed chain's batch progress, then record whether the whole
// indexer has caught up (every chain reached endblock or processed to head,
// with no processable events left). Catching up doesn't make the indexer ready:
// the deferred schema indexes still have to be created, which `markReady`
// below concludes once they're committed.
let applyBatchProgress = (crossChainState: t, ~batch: Batch.t, ~blockTimestampName: string) => {
  let chainIds = crossChainState.chainIds

  let everyChainCaughtUp = ref(true)
  for i in 0 to chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(chainIds->Array.getUnsafe(i))
    cs->ChainState.applyBatchProgress(~batch, ~blockTimestampName)
    if !(cs->ChainState.hasCaughtUp) {
      everyChainCaughtUp := false
    }
  }

  crossChainState.isCaughtUp =
    crossChainState.isCaughtUp ||
    (!crossChainState.holdRealtime &&
    crossChainState->nextItemIsNone &&
    everyChainCaughtUp.contents)
}

// Every chain has buffered up to its head (or endblock) with nothing
// processable left. Derived from current state rather than from the flag a
// progressed batch sets, because a run that reached the head and died before
// finalizing resumes with no batch to process — nothing would ever set it.
let isSettledAtHead = (crossChainState: t) => {
  let settled = ref(crossChainState->nextItemIsNone)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    if (
      !(
        crossChainState
        ->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
        ->ChainState.isFetchingAtHead
      )
    ) {
      settled := false
    }
  }
  settled.contents
}

// Enter the FinalizingIndexes phase without a batch, for the resume above.
// Not while the run holds this process back: the hold keeps the pre-threshold
// lag in place, and a chain that has fetched to a lagged head it was never
// going to get past reads as settled without having indexed anything. What a
// held process may conclude about where it stands, it concludes from what was
// persisted — see `markCaughtUpOnResume`, which the hold leaves alone.
let markCaughtUpIfSettled = (crossChainState: t) =>
  if !crossChainState.holdRealtime && crossChainState->isSettledAtHead {
    crossChainState.isCaughtUp = true
  }

// The same resume, decided from persisted values at construction instead of from
// the fetch frontier. A run that reached the head and died before finalizing has
// no batch to process on resume, and by the time the first height lands the head
// may have moved on — at which point no chain looks at head any more and the
// indexes it still owes would wait out another whole backfill. Deciding here,
// before any source request, keeps that debt tied to the progress that was
// actually committed. Skipped when the run resumed realtime, which is exactly
// the case where the indexes are already committed and nothing is owed.
let markCaughtUpOnResume = (crossChainState: t) => {
  let everyChainCaughtUp = ref(crossChainState.chainIds->Array.length > 0)
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    if !(cs->ChainState.hasCaughtUp) {
      everyChainCaughtUp := false
    }
  }

  if everyChainCaughtUp.contents && !crossChainState.isRealtime && crossChainState->nextItemIsNone {
    crossChainState.isCaughtUp = true
  }
}

// Concludes the FinalizingIndexes phase: stamps every chain this process drives
// with the `ready_at` already committed alongside their deferred schema indexes,
// and switches the indexer to realtime.
let markReady = (crossChainState: t, ~readyAt) => {
  for i in 0 to crossChainState.chainIds->Array.length - 1 {
    let cs = crossChainState->getChainState(crossChainState.chainIds->Array.getUnsafe(i))
    let wasReady = cs->ChainState.isReady
    cs->ChainState.markReady(~readyAt)

    // One line per chain, because `ready_at` is one column per chain: what the
    // log says and what a reader finds in the row are the same fact.
    if !wasReady {
      cs
      ->ChainState.logger
      ->Logger.info("Ready. Fully indexed for queries.")
    }
  }
  crossChainState.isRealtime = true
}

// What a caught-up chain is waiting on before its process can finalize: the run
// holding the process back, or another chain it drives still behind. Read when
// the chain speaks, so "waiting" is said only while it is true.
let isWaitingOnOthers = (crossChainState: t, cs: ChainState.t) =>
  crossChainState.holdRealtime ||
  crossChainState.chainStates
  ->Dict.valuesToArray
  ->Array.some(other => other !== cs && !(other->ChainState.hasCaughtUp))

// Each chain that has just finished indexing, said once, by the chain it is
// about — so a chain that finishes early says so then, rather than when the
// last chain in its process catches up.
let reportFinished = (crossChainState: t) =>
  crossChainState.chainStates
  ->Dict.valuesToArray
  ->Array.forEach(cs =>
    switch cs->ChainState.takeFinished {
    | Some(EndBlock(block)) =>
      cs
      ->ChainState.logger
      ->Logger.info("Indexed to the end block. This chain is done.", ~params={"block": block})
    | Some(Backfill(block)) =>
      cs
      ->ChainState.logger
      ->Logger.info(
        crossChainState->isWaitingOnOthers(cs)
          ? "Finished backfill. Waiting for the other chains."
          : "Finished backfill.",
        ~params={"block": block},
      )
    | None => ()
    }
  )

// --- Fetch control. ---

// One fetch tick across the whole indexer: the plan hands out each chain's
// share of the pool of about `targetBufferSize` ready items as requests, or has
// the chain wait for a new block.
let checkAndFetch = async (
  crossChainState: t,
  ~dispatchChain: IndexingPlan.chainFetchWork => promise<unit>,
) => {
  let ticks = crossChainState.chainIds->Array.map((chainId): IndexingPlan.chainTick => {
    let cs = crossChainState->getChainState(chainId)
    {
      chainId,
      processingBlockNumber: cs->ChainState.processingBlockNumber,
      processedDensity: ?(cs->ChainState.processedDensity),
    }
  })
  let works =
    crossChainState.indexingPlan->IndexingPlan.takeFetchRequestsToStart(
      ticks,
      ~isRealtime=crossChainState.isRealtime,
      ~targetBufferSize=crossChainState.targetBufferSize,
    )
  let _ = await works
  ->Array.map(work => {
    if work.requests->Utils.Array.notEmpty {
      crossChainState
      ->getChainState(work.chainId)
      ->ChainState.logger
      ->Logger.trace(
        "Started querying",
        ~params={
          "requests": work.requests->Array.map(request =>
            {
              "fromBlock": request->IndexingPlan.Request.fromBlock,
              "toBlock": request->IndexingPlan.Request.toBlock,
              "targetEvents": request->IndexingPlan.Request.itemsEstimate,
            }
          ),
        },
      )
    }
    dispatchChain(work)
  })
  ->Promise.all
}
