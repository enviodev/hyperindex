// The single batch-processing loop. Re-enters fetch/rollback through the
// injected schedule* effects.

// Yield to the end of the current tick so fetch responses that resolved this
// tick land before the processing loop builds its first batch (coalescing).
@inline
let yieldTick = () => Promise.make((resolve, _) => NodeJs.setImmediate(() => resolve()))

// The single processing loop. Runs batches back-to-back while there's work and
// no reorg is being resolved; exits when idle so producers (fetch, rollback) can
// re-kick it. `state.isProcessing` guarantees one instance. The loop
// decides whether to keep going by inspecting state after each batch, rather than
// from a return value of processNextBatch.
let rec startProcessing = async (state: IndexerState.t, ~scheduleFetch, ~scheduleRollback) => {
  if !(state->IndexerState.isProcessing) && !(state->IndexerState.isStopped) {
    state->IndexerState.beginProcessing
    // FIXME: Needed only for test determinism. The mocks resolve several fetch
    // responses synchronously in one tick; this yield lets them all land before
    // the first createBatch so they coalesce into one batch (matching the old
    // setImmediate model). In production responses arrive on separate network
    // ticks and never co-arrive, so this never coalesces anything real — remove
    // it later to avoid an unnecessary setImmediate per processing burst.
    await yieldTick()
    // Seeded true so the first batch always runs (it handles the caught-up exit
    // even when there's nothing to process, eg resuming fully-synced state).
    // Keep looping only while the last batch actually processed something: an
    // empty/idle batch records nothing, so the counter stays put and the loop
    // exits, leaving producers (fetch, rollback) to re-kick it.
    let hasMoreWork = ref(true)
    while (
      hasMoreWork.contents &&
      !(state->IndexerState.isStopped) &&
      !(state->IndexerState.isResolvingReorg)
    ) {
      let processedBatchesBefore = state->IndexerState.processedBatchesCount
      switch await processNextBatch(state, ~scheduleFetch) {
      | exception exn =>
        IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=IndexerState.unexpectedErrorMsg))
      | () => hasMoreWork := state->IndexerState.processedBatchesCount > processedBatchesBefore
      }
    }
    state->IndexerState.endProcessing

    // A reorg detected mid-batch parks the rollback until the loop is idle.
    // Hand off now that no batch is in flight.
    if state->IndexerState.isResolvingReorg {
      scheduleRollback()
    }
  }
}

and processNextBatch = async (state: IndexerState.t, ~scheduleFetch): unit => {
  // The reorg-threshold and queue updates below advance the chain states for the
  // next round, but the current batch is created and processed against the chain
  // states as they are now.
  let isInReorgThresholdBeforeUpdate = state->IndexerState.isInReorgThreshold
  let isRealtimeBeforeUpdate = state->IndexerState.isRealtime

  let isRollbackBatch = switch state->IndexerState.rollbackState {
  | RollbackReady(_) => true
  | _ => false
  }

  let batch =
    state->IndexerState.createBatch(
      ~processedCheckpointId=state->IndexerState.processedCheckpointId,
      ~batchSizeTarget=(state->IndexerState.config).batchSize,
      ~isRollback=isRollbackBatch,
    )

  let progressedChainsById = batch.progressedChainsById

  let isBelowReorgThreshold =
    !isInReorgThresholdBeforeUpdate && (state->IndexerState.config).shouldRollbackOnReorg
  let shouldEnterReorgThreshold =
    isBelowReorgThreshold &&
    state
    ->IndexerState.chainStates
    ->Dict.valuesToArray
    ->Array.every(cs => cs->ChainState.isReadyToEnterReorgThresholdAfterBatch(~batch))

  if shouldEnterReorgThreshold {
    IndexerState.enterReorgThreshold(state)
  }

  if progressedChainsById->Utils.Dict.isEmpty {
    if shouldEnterReorgThreshold {
      scheduleFetch()
    }

    // When resuming from persisted state, all events may already be processed.
    if EventProcessing.allChainsEventsProcessedToEndblock(state->IndexerState.chainStates) {
      Logging.info("All chains are caught up to end blocks.")
      if !(state->IndexerState.keepProcessAlive) {
        await ExitOnCaughtUp.run(state)
      }
    }
  } else {
    // The batch was created from pre-threshold fetch states, so advanceAfterBatch
    // applies blockLag when crossing the threshold; enterReorgThreshold already
    // covered the non-progressed chain states.
    state
    ->IndexerState.chainStates
    ->Utils.Dict.forEach(cs =>
      cs->ChainState.advanceAfterBatch(~batch, ~enteringReorgThreshold=shouldEnterReorgThreshold)
    )
    // Kick the next fetch round before awaiting the batch. A response that
    // lands mid-batch commits only fetch-frontier fields (buffer, knownHeight),
    // while applyBatchProgress below commits only progress fields, so the two
    // concurrent writes are disjoint and neither clobbers the other.
    scheduleFetch()

    state->InMemoryStore.setBatchDcs(~batch)

    // An exception here propagates to startProcessing's catch, the single error
    // boundary for the loop. The Error case is not an exception, so it's handled
    // here to preserve the handler's user-facing message.
    switch await EventProcessing.processEventBatch(
      ~batch,
      ~indexerState=state,
      ~loadManager=state->IndexerState.loadManager,
      ~persistence=state->IndexerState.persistence,
      ~config=state->IndexerState.config,
      ~chainStates=state->IndexerState.chainStates,
    ) {
    | Error(errHandler) => IndexerState.errorExit(state, errHandler)
    | Ok() =>
      state->IndexerState.recordProcessedBatch

      switch state->IndexerState.simulateDeadInputTracker {
      | Some(tracker) => tracker->SimulateDeadInputTracker.recordProcessed(~batch)
      | None => ()
      }

      if state->IndexerState.isResolvingReorg {
        // A reorg landed while this batch was processing. Apply its progress so
        // the rollback diff is computed against up-to-date chain progress, but
        // don't reset rollback state or evaluate exit. The loop exit hands off
        // to rollback.
        state->IndexerState.applyBatchProgress(~batch)
      } else {
        // Can safely reset rollback state, since overwrite is not possible.
        state->IndexerState.clearRollback
        state->IndexerState.applyBatchProgress(~batch)

        if !isRealtimeBeforeUpdate && state->IndexerState.isRealtime {
          // Catching up just flipped the chain to realtime, which changes the
          // active source for waitForNewBlock (eg sync -> live). The waiter that
          // parked during backfill is bound to the old source; bump the epoch to
          // invalidate it and kick a fresh fetch that parks on the realtime source.
          state->IndexerState.invalidateInflight
          scheduleFetch()
        }

        let allCaughtUp = EventProcessing.allChainsEventsProcessedToEndblock(
          state->IndexerState.chainStates,
        )
        if allCaughtUp {
          Logging.info("All chains are caught up to end blocks.")
        }

        if allCaughtUp && !(state->IndexerState.keepProcessAlive) {
          await ExitOnCaughtUp.run(state)
        } else if (
          // In auto-exit mode, error if all chains reached head with no events found
          !allCaughtUp &&
          state->IndexerState.exitAfterFirstEventBlock &&
          state
          ->IndexerState.chainStates
          ->Dict.valuesToArray
          ->Array.every(ChainState.isAtHeadWithoutEndBlock)
        ) {
          IndexerState.errorExit(
            state,
            ErrorHandling.make(
              Utils.Error.make(
                "No events found between startBlock and chain head. Cannot auto-detect endBlock.",
              ),
            ),
          )
        } else {
          ChainMetadata.stage(state)
          if (
            state
            ->IndexerState.config
            ->Config.shouldPruneHistory(~isInReorgThreshold=state->IndexerState.isInReorgThreshold)
          ) {
            state->PruneStaleHistory.schedule
          }
        }
      }
    }
  }
}
