// The single batch-processing loop. Re-enters fetch/rollback through the
// injected schedule* effects.

// Yield to the end of the current tick so fetch responses that resolved this
// tick land before the processing loop builds its first batch (coalescing).
@inline
let yieldTick = () => Promise.make((resolve, _) => NodeJs.setImmediate(() => resolve()))

// The single processing loop. Runs batches back-to-back while there's work and
// no reorg is being resolved; exits when idle so producers (fetch, rollback) can
// re-kick it. `inMemoryStore.isProcessing` guarantees one instance. The loop
// decides whether to keep going by inspecting state after each batch, rather than
// from a return value of processNextBatch.
let rec startProcessing = async (
  state: IndexerState.t,
  ~scheduleFetchAllChains,
  ~scheduleRollback,
) => {
  if !(state->IndexerState.isProcessing) && !state.isStopped {
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
    while hasMoreWork.contents && !state.isStopped && !(state->IndexerState.isResolvingReorg) {
      let processedBatchesBefore = state.inMemoryStore.processedBatchesCount
      switch await processNextBatch(state, ~scheduleFetchAllChains) {
      | exception exn =>
        IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=IndexerState.unexpectedErrorMsg))
      | () => hasMoreWork := state.inMemoryStore.processedBatchesCount > processedBatchesBefore
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

and processNextBatch = async (state: IndexerState.t, ~scheduleFetchAllChains): unit => {
  // The reorg-threshold and queue updates below advance chainManager for the
  // next round, but the current batch is created and processed against the
  // fetchers as they are now.
  let chainManagerBeforeUpdate = state.chainManager

  let isRollbackBatch = switch state.rollbackState {
  | RollbackReady(_) => true
  | _ => false
  }

  let batch =
    chainManagerBeforeUpdate->ChainManager.createBatch(
      ~processedCheckpointId=state.inMemoryStore.processedCheckpointId,
      ~batchSizeTarget=state.config.batchSize,
      ~isRollback=isRollbackBatch,
    )

  let progressedChainsById = batch.progressedChainsById

  let isBelowReorgThreshold =
    !chainManagerBeforeUpdate.isInReorgThreshold && state.config.shouldRollbackOnReorg
  let shouldEnterReorgThreshold =
    isBelowReorgThreshold &&
    chainManagerBeforeUpdate.chainFetchers
    ->ChainMap.values
    ->Array.every(chainFetcher => {
      let fetchState = switch progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
        chainFetcher.fetchState.chainId,
      ) {
      | Some(chainAfterBatch) => chainAfterBatch.fetchState
      | None => chainFetcher.fetchState
      }
      fetchState->FetchState.isReadyToEnterReorgThreshold
    })

  if shouldEnterReorgThreshold {
    IndexerState.enterReorgThreshold(state)
  }

  if progressedChainsById->Utils.Dict.isEmpty {
    if shouldEnterReorgThreshold {
      scheduleFetchAllChains()
    }

    // When resuming from persisted state, all events may already be processed.
    if EventProcessing.allChainsEventsProcessedToEndblock(chainManagerBeforeUpdate.chainFetchers) {
      Logging.info("All chains are caught up to end blocks.")
      if !state.keepProcessAlive {
        await ExitOnCaughtUp.run(state)
      }
    }
  } else {
    let inMemoryStore = state.inMemoryStore

    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      switch progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
        chain->ChainMap.Chain.toChainId,
      ) {
      | Some(chainAfterBatch) => {
          ...cf,
          // The batch was created from pre-threshold fetch states, so blockLag
          // is applied here; enterReorgThreshold already covered the
          // non-progressed fetchers.
          fetchState: shouldEnterReorgThreshold
            ? chainAfterBatch.fetchState->FetchState.updateInternal(
                ~blockLag=cf.chainConfig.blockLag,
              )
            : chainAfterBatch.fetchState,
        }
      | None => cf
      }
    })
    state->IndexerState.setChainFetchers(chainFetchers)
    // Kick the next fetch round before awaiting the batch. A response that
    // lands mid-batch commits only fetch-frontier fields (buffer, knownHeight)
    // via setChainFetcher(s), while applyBatchProgress below commits only
    // progress fields, so the two concurrent writes are disjoint and neither
    // clobbers the other.
    scheduleFetchAllChains()

    inMemoryStore->InMemoryStore.setBatchDcs(~batch)

    // An exception here propagates to startProcessing's catch, the single error
    // boundary for the loop. The Error case is not an exception, so it's handled
    // here to preserve the handler's user-facing message.
    switch await EventProcessing.processEventBatch(
      ~batch,
      ~inMemoryStore,
      ~loadManager=state.loadManager,
      ~persistence=state.persistence,
      ~config=state.config,
      ~chainFetchers=chainManagerBeforeUpdate.chainFetchers,
    ) {
    | Error(errHandler) => IndexerState.errorExit(state, errHandler)
    | Ok() =>
      state->IndexerState.recordProcessedBatch

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

        if !chainManagerBeforeUpdate.isRealtime && state.chainManager.isRealtime {
          // Catching up just flipped the chain to realtime, which changes the
          // active source for waitForNewBlock (eg sync -> live). The waiter that
          // parked during backfill is bound to the old source; bump the epoch to
          // invalidate it and kick a fresh fetch that parks on the realtime source.
          state->IndexerState.invalidateInflight
          scheduleFetchAllChains()
        }

        let allCaughtUp = EventProcessing.allChainsEventsProcessedToEndblock(
          state.chainManager.chainFetchers,
        )
        if allCaughtUp {
          Logging.info("All chains are caught up to end blocks.")
        }

        if allCaughtUp && !state.keepProcessAlive {
          await ExitOnCaughtUp.run(state)
        } else if (
          // In auto-exit mode, error if all chains reached head with no events found
          !allCaughtUp &&
          state.exitAfterFirstEventBlock &&
          state.chainManager.chainFetchers
          ->ChainMap.values
          ->Array.every(cf => cf.isProgressAtHead && cf.fetchState.endBlock->Option.isNone)
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
            state.config->Config.shouldPruneHistory(
              ~isInReorgThreshold=state.chainManager.isInReorgThreshold,
            )
          ) {
            state->PruneStaleHistory.schedule
          }
        }
      }
    }
  }
}
