// Fetch orchestration and query-response handling. Re-enters the loop only
// through the injected schedule* effects; everything else points at IndexerState
// (state + transitions) and leaf effect modules.

type partitionQueryResponse = {
  chain: IndexerState.chain,
  response: Source.blockRangeFetchResponse,
  query: FetchState.query,
}

let rec onQueryResponse = async (
  state: IndexerState.t,
  {chain, response, query}: partitionQueryResponse,
  ~stateId,
  ~scheduleFetchChain,
  ~scheduleProcessing,
  ~scheduleRollback,
) =>
  if state->IndexerState.isStale(~stateId) {
    ()
  } else {
    let originalChainManager = state.chainManager
    let chainFetcher = originalChainManager.chainFetchers->ChainMap.get(chain)
    let {
      parsedQueueItems,
      latestFetchedBlockNumber,
      latestFetchedBlockTimestamp,
      stats,
      knownHeight,
      blockHashes,
      fromBlockQueried,
    } = response

    if knownHeight > chainFetcher.fetchState.knownHeight {
      Prometheus.SourceHeight.set(
        ~blockNumber=knownHeight,
        ~chainId=chainFetcher.chainConfig.id,
        // The knownHeight from response won't necessarily
        // belong to the currently active source.
        // But for simplicity, assume it does.
        ~sourceName=(chainFetcher.sourceManager->SourceManager.getActiveSource).name,
      )
    }

    Prometheus.FetchingBlockRange.increment(
      ~chainId=chain->ChainMap.Chain.toChainId,
      ~totalTimeElapsed=stats.totalTimeElapsed,
      ~parsingTimeElapsed=stats.parsingTimeElapsed->Option.getOr(0.),
      ~numEvents=parsedQueueItems->Array.length,
      ~blockRangeSize=latestFetchedBlockNumber - fromBlockQueried + 1,
    )

    let (updatedReorgDetection, reorgResult: ReorgDetection.reorgResult) =
      chainFetcher.reorgDetection->ReorgDetection.registerReorgGuard(~blockHashes, ~knownHeight)

    let rollbackWithReorgDetectedBlockNumber = switch reorgResult {
    | ReorgDetected(reorgDetected) => {
        chainFetcher.logger->Logging.childInfo(
          reorgDetected->ReorgDetection.reorgDetectedToLogParams(
            ~shouldRollbackOnReorg=state.ctx.config.shouldRollbackOnReorg,
          ),
        )
        Prometheus.ReorgCount.increment(~chain)
        Prometheus.ReorgDetectionBlockNumber.set(
          ~blockNumber=reorgDetected.scannedBlock.blockNumber,
          ~chain,
        )
        if state.ctx.config.shouldRollbackOnReorg {
          Some(reorgDetected.scannedBlock.blockNumber)
        } else {
          None
        }
      }
    | NoReorg => None
    }

    switch rollbackWithReorgDetectedBlockNumber {
    | Some(reorgDetectedBlockNumber) =>
      let restoredChainFetchers = switch state.rollbackState {
      | RollbackReady({eventsProcessedDiffByChain}) =>
        // Restore event counters for ALL chains, not just the reorg chain.
        // The previous rollback subtracted from all chains' counters,
        // but was never committed to DB. So we must undo the subtraction
        // for every chain before the new rollback subtracts again.
        originalChainManager.chainFetchers->ChainMap.mapWithKey((c, chainFetcher) => {
          switch eventsProcessedDiffByChain->Utils.Dict.dangerouslyGetByIntNonOption(
            c->ChainMap.Chain.toChainId,
          ) {
          | Some(eventsProcessedDiff) => {
              ...chainFetcher,
              // Since we detected a reorg, until rollback wasn't completed in the db
              // We return the events processed counter to the pre-rollback value,
              // to decrease it once more for the new rollback.
              numEventsProcessed: chainFetcher.numEventsProcessed +. eventsProcessedDiff,
            }
          | None => chainFetcher
          }
        })
      | _ => originalChainManager.chainFetchers
      }
      let chainManager = {
        ...originalChainManager,
        chainFetchers: restoredChainFetchers->ChainMap.map(chainFetcher => {
          ...chainFetcher,
          // TODO: It's not optimal to abort pending queries for all chains,
          // this is how it always worked, but we should consider a better approach.
          fetchState: chainFetcher.fetchState->FetchState.resetPendingQueries,
        }),
      }
      state->IndexerState.beginReorg(~chain, ~blockNumber=reorgDetectedBlockNumber, ~chainManager)
      // Advances synchronously to FindingReorgDepth, so a concurrent rollback
      // kick (eg from the processing loop quiescing) collapses into this one.
      scheduleRollback()
    | None =>
      state->IndexerState.setChainFetcher(
        ~chain,
        {...chainFetcher, reorgDetection: updatedReorgDetection},
      )

      let itemsWithContractRegister = []
      let newItems = []
      for idx in 0 to parsedQueueItems->Array.length - 1 {
        let item = parsedQueueItems->Array.getUnsafe(idx)
        let eventItem = item->Internal.castUnsafeEventItem
        if eventItem.eventConfig.contractRegister !== None {
          itemsWithContractRegister->Array.push(item)
        }
        // TODO: Don't really need to keep it in the queue
        // when there's no handler (besides raw_events, processed counter, and dcsToStore consuming)
        newItems->Array.push(item)
      }

      // Re-check staleness: contract registration is async, so the chain state
      // may have rolled back by the time we apply the fetched items.
      let proceed = (~newItemsWithDcs) =>
        if !(state->IndexerState.isStale(~stateId)) {
          applyQueryResponse(
            state,
            ~chain,
            ~newItems,
            ~newItemsWithDcs,
            ~knownHeight,
            ~latestFetchedBlock={
              FetchState.blockNumber: latestFetchedBlockNumber,
              blockTimestamp: latestFetchedBlockTimestamp,
            },
            ~query,
          )
          ChainMetadata.stage(state)
          scheduleFetchChain(chain)
          scheduleProcessing()
        }

      switch itemsWithContractRegister {
      | [] => proceed(~newItemsWithDcs=[])
      | _ =>
        switch await ChainFetcher.runContractRegistersOrThrow(
          ~itemsWithContractRegister,
          ~config=state.ctx.config,
        ) {
        | exception exn => IndexerState.errorExit(state, exn->ErrorHandling.make)
        | newItemsWithDcs => proceed(~newItemsWithDcs)
        }
      }
    }
  }

and applyQueryResponse = (
  state: IndexerState.t,
  ~chain,
  ~newItems,
  ~newItemsWithDcs,
  ~knownHeight,
  ~latestFetchedBlock,
  ~query,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)

  let updatedChainFetcher =
    chainFetcher->ChainFetcher.handleQueryResult(
      ~query,
      ~latestFetchedBlock,
      ~newItems,
      ~newItemsWithDcs,
      ~knownHeight,
    )

  // In auto-exit mode, set endBlock to the first event's block when events arrive.
  // Also update if a partition returns events at an earlier block than current endBlock.
  let updatedChainFetcher = if state.exitAfterFirstEventBlock && newItems->Array.length > 0 {
    let firstEventBlock = newItems->Array.getUnsafe(0)->Internal.getItemBlockNumber
    switch updatedChainFetcher.fetchState.endBlock {
    | None => {
        ...updatedChainFetcher,
        fetchState: {...updatedChainFetcher.fetchState, endBlock: Some(firstEventBlock)},
      }
    | Some(currentEndBlock) if firstEventBlock < currentEndBlock => {
        ...updatedChainFetcher,
        fetchState: {...updatedChainFetcher.fetchState, endBlock: Some(firstEventBlock)},
      }
    | Some(_) => updatedChainFetcher
    }
  } else {
    updatedChainFetcher
  }

  if !chainFetcher.isProgressAtHead && updatedChainFetcher.isProgressAtHead {
    updatedChainFetcher.logger->Logging.childInfo("All events have been fetched")
  }

  state->IndexerState.setChainFetcher(~chain, updatedChainFetcher)
}

and finishWaitingForNewBlock = (
  state: IndexerState.t,
  ~chain,
  ~knownHeight,
  ~stateId,
  ~scheduleFetchAllChains,
  ~scheduleFetchChain,
  ~scheduleProcessing,
) =>
  if state->IndexerState.isStale(~stateId) {
    ()
  } else {
    let updatedChainFetchers = state.chainManager.chainFetchers->ChainMap.update(
      chain,
      chainFetcher => {
        let updatedFetchState = chainFetcher.fetchState->FetchState.updateKnownHeight(~knownHeight)
        if updatedFetchState !== chainFetcher.fetchState {
          {
            ...chainFetcher,
            fetchState: updatedFetchState,
          }
        } else {
          chainFetcher
        }
      },
    )

    let isBelowReorgThreshold =
      !state.chainManager.isInReorgThreshold && state.ctx.config.shouldRollbackOnReorg
    let shouldEnterReorgThreshold =
      isBelowReorgThreshold &&
      updatedChainFetchers
      ->ChainMap.values
      ->Array.every(chainFetcher => {
        chainFetcher.fetchState->FetchState.isReadyToEnterReorgThreshold
      })

    state->IndexerState.setChainFetchers(updatedChainFetchers)

    // Kick processing in case there are block handlers to run.
    if shouldEnterReorgThreshold {
      IndexerState.enterReorgThreshold(state)
      scheduleFetchAllChains()
    } else {
      scheduleFetchChain(chain)
    }
    scheduleProcessing()
  }

and checkAndFetchForChain = async (
  state: IndexerState.t,
  chain,
  ~stateId,
  ~scheduleFetchAllChains,
  ~scheduleFetchChain,
  ~scheduleProcessing,
  ~scheduleRollback,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  if !(state->IndexerState.isResolvingReorg) && !state.isStopped {
    let {fetchState} = chainFetcher
    let isRealtime = state.chainManager.isRealtime

    // Only affects the WaitingForNewBlock branch of fetchNext, where
    // there's nothing to fetch. During backfill any such chain is idle.
    let reducedPolling = !isRealtime

    // Owns its error boundary: launch doesn't catch, so any failure here (the
    // query, response handling, or fetchNext itself) must stop the indexer.
    try {
      await chainFetcher.sourceManager->SourceManager.fetchNext(
        ~fetchState,
        ~waitForNewBlock=(~knownHeight) =>
          chainFetcher.sourceManager->SourceManager.waitForNewBlock(
            ~knownHeight,
            ~isRealtime,
            ~reducedPolling,
          ),
        ~onNewBlock=(~knownHeight) =>
          finishWaitingForNewBlock(
            state,
            ~chain,
            ~knownHeight,
            ~stateId,
            ~scheduleFetchAllChains,
            ~scheduleFetchChain,
            ~scheduleProcessing,
          ),
        ~executeQuery=async query => {
          // Caught here (not just by the outer try) so the query promise never
          // rejects: fetchNext spins a side-chain off it that would otherwise
          // become an unhandled rejection.
          try {
            let response = await chainFetcher.sourceManager->SourceManager.executeQuery(
              ~query,
              ~knownHeight=fetchState.knownHeight,
              ~isRealtime,
            )
            await onQueryResponse(
              state,
              {chain, response, query},
              ~stateId,
              ~scheduleFetchChain,
              ~scheduleProcessing,
              ~scheduleRollback,
            )
          } catch {
          | exn => IndexerState.errorExit(state, exn->ErrorHandling.make)
          }
        },
        ~stateId,
      )
    } catch {
    | exn =>
      IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=IndexerState.unexpectedErrorMsg))
    }
  }
}

and checkAndFetchAllChains = async (
  state: IndexerState.t,
  ~stateId,
  ~scheduleFetchAllChains,
  ~scheduleFetchChain,
  ~scheduleProcessing,
  ~scheduleRollback,
) => {
  //Mapping from the states chainManager so we can construct tests that don't use
  //all chains
  let _ = await state.chainManager.chainFetchers
  ->ChainMap.keys
  ->Array.map(chain =>
    checkAndFetchForChain(
      state,
      chain,
      ~stateId,
      ~scheduleFetchAllChains,
      ~scheduleFetchChain,
      ~scheduleProcessing,
      ~scheduleRollback,
    )
  )
  ->Promise.all
}
