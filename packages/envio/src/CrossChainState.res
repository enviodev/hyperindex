// Whole-indexer view over every chain's ChainState: the chain collection plus
// the run-wide flags derived from it. Owns the cross-chain reads and the
// batch/threshold transitions that touch every chain. `t` is mutated in place
// through the transitions below; the type is opaque in the interface.

type t = {
  chainStates: dict<ChainState.t>,
  // True once every chain has caught up to head/endBlock. Monotonic during a run.
  mutable isRealtime: bool,
  mutable isInReorgThreshold: bool,
  // Indexer-wide cap on concurrent data-source queries, shared across all chains.
  maxConcurrency: int,
}

let make = (
  ~chainStates,
  ~isInReorgThreshold,
  ~isRealtime,
  ~maxConcurrency=Env.maxConcurrency,
): t => {
  Prometheus.IndexingMaxConcurrency.set(~maxConcurrency)
  {
    chainStates,
    isRealtime,
    isInReorgThreshold,
    maxConcurrency,
  }
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

// --- Derived (pure). ---

let nextItemIsNone = (cm: t): bool =>
  !Batch.hasReadyItem(cm.chainStates->Dict.valuesToArray->Array.map(ChainState.fetchState))

let isProgressAtHead = (cm: t) =>
  cm.chainStates->Dict.valuesToArray->Array.every(ChainState.isProgressAtHead)

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

/**
Sets all chains' timestampCaughtUpToHeadOrEndblock when valid state lines up, and
commits each progressed chain's batch progress, mutating the chain states in place.
*/
let applyBatchProgress = (cm: t, ~batch: Batch.t) => {
  let nextQueueItemIsNone = cm->nextItemIsNone
  let allChainsAtHead = cm->isProgressAtHead
  let allChainsReady = ref(true)

  cm.chainStates->Utils.Dict.forEach(cs => {
    cs->ChainState.applyBatchProgress(~batch, ~allChainsAtHead, ~nextQueueItemIsNone)
    if !(cs->ChainState.isReady) {
      allChainsReady := false
    }
  })

  if allChainsReady.contents {
    Prometheus.ProgressReady.setAllReady()
  }

  cm.isRealtime = cm.isRealtime || allChainsReady.contents
}

// --- Fetch control. ---

// Dispatch a fetch tick across every chain, drawing from the shared concurrency
// budget. Chains are visited in turn; fetchChain bumps the in-flight count
// synchronously before it suspends, so a later chain sees the slots an earlier
// one already claimed and the budget is honored indexer-wide.
let checkAndFetch = async (
  cm: t,
  ~fetchChain: (~chain: ChainMap.Chain.t, ~concurrencyLimit: int) => promise<unit>,
) => {
  let _ = await cm.chainStates
  ->Dict.valuesToArray
  ->Array.map(cs => {
    let chain = ChainMap.Chain.makeUnsafe(~chainId=(cs->ChainState.chainConfig).id)
    let concurrencyLimit = Pervasives.max(0, cm.maxConcurrency - cm->inFlight)
    fetchChain(~chain, ~concurrencyLimit)
  })
  ->Promise.all
}
