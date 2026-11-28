// Fetch orchestration and query-response handling. Re-enters the loop only
// through the injected schedule* effects; everything else points at IndexerState
// (state + transitions) and leaf effect modules.

// Hands a response to the plan the moment its source returns it: the page
// joins the buffer, the request's needs move to the block the source reached,
// and the blocks holding a registering event join the contractRegister
// backlog. No user code runs here.
let onRequestResponse = (
  state: IndexerState.t,
  ~chainId,
  ~request,
  ~response: Source.blockRangeFetchResponse,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
  ~scheduleRollback,
  ~scheduleContractRegister,
) => {
  let chainState = state->IndexerState.getChainState(~chainId)
  if state->IndexerState.isStale(~stateId) {
    chainState->ChainState.abandonFetchRequest(~request)
  } else {
    let {page, latestFetchedBlockNumber, totalTimeElapsed} = response
    let fromBlock = request->IndexingPlan.Request.fromBlock
    // Read before the merge, which moves the page's rows out.
    let firstEventBlockNumber =
      state->IndexerState.exitAfterFirstEventBlock
        ? page->BufferPage.firstRowBlockNumber->Null.toOption
        : None

    switch chainState->ChainState.completeFetchRequest(~request, ~response) {
    | None => ()
    | Some(completion) =>
      chainState->ChainState.recordBlockRangeFetch(
        ~totalTimeElapsed,
        ~numEvents=completion.rowsKept,
        ~blockRangeSize=latestFetchedBlockNumber - fromBlock + 1,
      )
      chainState
      ->ChainState.logger
      ->Logger.trace(
        "Finished querying",
        ~params={
          "fromBlock": fromBlock,
          "toBlock": latestFetchedBlockNumber,
          "numEvents": completion.rowsKept,
          "numContractRegisterBlocks": completion.registeringBlockCount,
        },
      )

      let rollbackWithReorgDetectedBlockNumber = switch completion.mismatch {
      | Some({blockNumber, storedHash, receivedHash}) => {
          chainState
          ->ChainState.logger
          ->Logger.info(
            `Blockchain reorg detected. ${chainState->ChainState.shouldRollbackOnReorg
                ? "Initiating indexer rollback"
                : "NOT initiating indexer rollback due to configuration"}.`,
            ~params={
              "blockNumber": blockNumber,
              "indexedBlockHash": storedHash,
              "receivedBlockHash": receivedHash,
            },
          )
          chainState->ChainState.recordReorgDetected(~blockNumber)

          // With rollback on nothing of the page merged, so the rollback has
          // to happen, or the stale stored hash re-reports forever.
          chainState->ChainState.shouldRollbackOnReorg ? Some(blockNumber) : None
        }
      | None => None
      }

      switch rollbackWithReorgDetectedBlockNumber {
      | Some(reorgDetectedBlockNumber) =>
        // Prepare every chain for the rollback: restore each events-processed
        // counter (the previous, uncommitted rollback subtracted from all chains,
        // so undo that before the new rollback subtracts again) and drop the
        // requests asked against the about-to-be-invalidated chain state.
        let eventsProcessedDiffByChain = switch state->IndexerState.rollbackState {
        | RollbackReady({eventsProcessedDiffByChain}) => Some(eventsProcessedDiffByChain)
        | _ => None
        }
        state
        ->IndexerState.chainStates
        ->Utils.Dict.forEach(cs =>
          cs->ChainState.prepareReorg(
            ~eventsProcessedDiff=switch eventsProcessedDiffByChain {
            | Some(byChain) =>
              byChain->ChainId.Dict.dangerouslyGetNonOption((cs->ChainState.chainConfig).id)
            | None => None
            },
          )
        )
        state->IndexerState.beginReorg(~chainId, ~blockNumber=reorgDetectedBlockNumber)
        // Advances synchronously to FindingReorgDepth, so a concurrent rollback
        // kick (eg from the processing loop quiescing) collapses into this one.
        scheduleRollback()
      // No rollback: either no reorg, or one this chain only reports. Either way
      // the page has merged.
      | None =>
        // In auto-exit mode, set endBlock to the first event's block when events arrive.
        switch firstEventBlockNumber {
        | Some(blockNumber) => chainState->ChainState.setEndBlockToFirstEvent(~blockNumber)
        | None => ()
        }
        ChainMetadata.stage(state)
        scheduleFetch()
        if completion.registeringBlockCount > 0 {
          scheduleContractRegister(chainId)
        }
        scheduleProcessing()
      }
    }
  }
}

let finishWaitingForNewBlock = (
  state: IndexerState.t,
  ~chainId,
  ~knownHeight,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
) =>
  if state->IndexerState.isStale(~stateId) {
    ()
  } else {
    let chainState = state->IndexerState.getChainState(~chainId)
    chainState->ChainState.updateKnownHeight(~knownHeight)

    // No reorg-threshold check here: scheduleProcessing always runs at least one
    // processNextBatch (even with no items), which owns the entry decision.
    scheduleFetch()
    scheduleProcessing()
  }

let fetchChain = async (
  state: IndexerState.t,
  ~work: IndexingPlan.chainFetchWork,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
  ~scheduleRollback,
  ~scheduleContractRegister,
) => {
  let chainId = work.chainId
  let chainState = state->IndexerState.getChainState(~chainId)
  if !(state->IndexerState.isResolvingReorg) && !(state->IndexerState.isStopped) {
    let isRealtime = state->IndexerState.isRealtime
    let sourceManager = chainState->ChainState.sourceManager

    // Only affects the WaitingForNewBlock branch of dispatch, where there's
    // nothing to fetch. The line is whether any height is known at all, not
    // whether the head is fetchable yet: a chain held back by its lag is still
    // tracking a head it has, and asking faster would buy nothing. A chain with
    // no height has nothing to show for itself until the first one lands, so it
    // polls at the source's own cadence and earns the normal stall window.
    let reducedPolling = !isRealtime && chainState->ChainState.knownHeight > 0

    // Owns its error boundary: launch doesn't catch, so any failure here (the
    // query, response handling, or dispatch itself) must stop the indexer.
    try {
      await sourceManager->SourceManager.dispatch(
        ~knownHeight=chainState->ChainState.knownHeight,
        ~waitForNewBlock=(~knownHeight) =>
          sourceManager->SourceManager.waitForNewBlock(~knownHeight, ~isRealtime, ~reducedPolling),
        ~onNewBlock=(~knownHeight) =>
          finishWaitingForNewBlock(
            state,
            ~chainId,
            ~knownHeight,
            ~stateId,
            ~scheduleFetch,
            ~scheduleProcessing,
          ),
        ~executeQuery=async request => {
          // Caught here (not just by the outer try) so the query promise never
          // rejects: dispatch spins a side-chain off it that would otherwise
          // become an unhandled rejection.
          try {
            switch await sourceManager->SourceManager.executeQuery(
              ~request,
              ~knownHeight=chainState->ChainState.knownHeight,
              ~isRealtime,
              ~reorgableFrom=chainState->ChainState.reorgableFrom(~isRealtime),
              ~isStale=() => state->IndexerState.isStale(~stateId),
            ) {
            | Some(response) =>
              onRequestResponse(
                state,
                ~chainId,
                ~request,
                ~response,
                ~stateId,
                ~scheduleFetch,
                ~scheduleProcessing,
                ~scheduleRollback,
                ~scheduleContractRegister,
              )
            | None => chainState->ChainState.abandonFetchRequest(~request)
            }
          } catch {
          | exn =>
            IndexerState.errorExit(
              state,
              exn->ErrorHandling.make(~logger=state->IndexerState.logger),
            )
          }
        },
        ~work,
        ~stateId,
      )
    } catch {
    | exn =>
      IndexerState.errorExit(
        state,
        exn->ErrorHandling.make(
          ~logger=state->IndexerState.logger,
          ~msg=IndexerState.unexpectedErrorMsg,
        ),
      )
    }
  }
}
