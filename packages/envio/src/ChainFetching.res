// Fetch orchestration and query-response handling. Re-enters the loop only
// through the injected schedule* effects; everything else points at IndexerState
// (state + transitions) and leaf effect modules.

type partitionQueryResponse = {
  chainId: ChainId.t,
  response: Source.blockRangeFetchResponse,
  query: FetchState.query,
}

// Applies a response the moment its source returns it: the page joins the
// buffer, the partition advances, and the blocks holding a registering event
// join the contractRegister backlog. No user code runs here.
let onQueryResponse = (
  state: IndexerState.t,
  {chainId, response, query}: partitionQueryResponse,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
  ~scheduleRollback,
  ~scheduleContractRegister,
) =>
  if !(state->IndexerState.isStale(~stateId)) {
    let chainState = state->IndexerState.getChainState(~chainId)
    let {page, latestFetchedBlockNumber, stats, knownHeight} = response
    // Read before the merge, which moves the page's rows out.
    let firstEventBlockNumber =
      state->IndexerState.exitAfterFirstEventBlock
        ? page->BufferPage.firstRowBlockNumber->Null.toOption
        : None

    let (reorgResult, merged) = chainState->ChainState.mergePage(~page, ~knownHeight)

    chainState->ChainState.recordBlockRangeFetch(
      ~totalTimeElapsed=stats.totalTimeElapsed,
      ~numEvents=merged.rowsKept,
      ~blockRangeSize=latestFetchedBlockNumber - query.fromBlock + 1,
    )
    chainState
    ->ChainState.logger
    ->Logger.trace(
      "Finished querying",
      ~params={
        "partitionId": query.partitionId,
        "fromBlock": query.fromBlock,
        "toBlock": latestFetchedBlockNumber,
        "numEvents": merged.rowsKept,
        "numContractRegisterBlocks": merged.registeringBlockNumbers->Array.length,
      },
    )

    let rollbackWithReorgDetectedBlockNumber = switch reorgResult {
    | ReorgDetected({scannedBlock, receivedBlock}) => {
        chainState
        ->ChainState.logger
        ->Logger.info(
          `Blockchain reorg detected. ${chainState->ChainState.shouldRollbackOnReorg
              ? "Initiating indexer rollback"
              : "NOT initiating indexer rollback due to configuration"}.`,
          ~params={
            "blockNumber": scannedBlock.blockNumber,
            "indexedBlockHash": scannedBlock.blockHash,
            "receivedBlockHash": receivedBlock.blockHash,
          },
        )
        chainState->ChainState.recordReorgDetected(~blockNumber=scannedBlock.blockNumber)

        // Must agree with the `reportOnly` flag the merge was given: a page
        // left out (rollback mode) needs the rollback to actually happen, or
        // the stale stored hash re-reports forever.
        if chainState->ChainState.shouldRollbackOnReorg {
          Some(scannedBlock.blockNumber)
        } else {
          None
        }
      }
    | NoReorg => None
    }

    switch rollbackWithReorgDetectedBlockNumber {
    | Some(reorgDetectedBlockNumber) =>
      // Prepare every chain for the rollback: restore each events-processed
      // counter (the previous, uncommitted rollback subtracted from all chains,
      // so undo that before the new rollback subtracts again) and drop pending
      // queries requested against the about-to-be-invalidated chain state.
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
      chainState->ChainState.handleQueryResult(
        ~query,
        ~itemsCount=merged.rowsKept,
        ~registeringBlockNumbers=merged.registeringBlockNumbers,
        ~latestFetchedBlock=latestFetchedBlockNumber,
        ~knownHeight,
      )
      // In auto-exit mode, set endBlock to the first event's block when events arrive.
      switch firstEventBlockNumber {
      | Some(blockNumber) => chainState->ChainState.setEndBlockToFirstEvent(~blockNumber)
      | None => ()
      }
      ChainMetadata.stage(state)
      scheduleFetch()
      if merged.registeringBlockNumbers->Utils.Array.notEmpty {
        scheduleContractRegister(chainId)
      }
      scheduleProcessing()
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
  chainId,
  ~action,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
  ~scheduleRollback,
  ~scheduleContractRegister,
) => {
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
      await chainState->ChainState.dispatch(
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
        ~executeQuery=async query => {
          // Caught here (not just by the outer try) so the query promise never
          // rejects: dispatch spins a side-chain off it that would otherwise
          // become an unhandled rejection.
          try {
            switch await sourceManager->SourceManager.executeQuery(
              ~query,
              ~knownHeight=chainState->ChainState.knownHeight,
              ~isRealtime,
              ~reorgableFrom=chainState->ChainState.reorgableFrom(~isRealtime),
              ~isStale=() => state->IndexerState.isStale(~stateId),
            ) {
            | Some(response) =>
              onQueryResponse(
                state,
                {chainId, response, query},
                ~stateId,
                ~scheduleFetch,
                ~scheduleProcessing,
                ~scheduleRollback,
                ~scheduleContractRegister,
              )
            | None => ()
            }
          } catch {
          | exn =>
            IndexerState.errorExit(
              state,
              exn->ErrorHandling.make(~logger=state->IndexerState.logger),
            )
          }
        },
        ~action,
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
