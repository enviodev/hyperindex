// Fetch orchestration and query-response handling. Re-enters the loop only
// through the injected schedule* effects; everything else points at IndexerState
// (state + transitions) and leaf effect modules.

type partitionQueryResponse = {
  chain: IndexerState.chain,
  response: Source.blockRangeFetchResponse,
  query: FetchState.query,
}

let runContractRegistersOrThrow = async (
  ~itemsWithContractRegister: array<Internal.item>,
  ~config: Config.t,
) => {
  let itemsWithDcs = []

  let onRegister = (~item: Internal.item, ~contractAddress, ~contractName) => {
    let eventItem = item->Internal.castUnsafeEventItem
    let {blockNumber} = eventItem

    let dc: Internal.indexingAddress = {
      address: contractAddress,
      contractName,
      registrationBlock: blockNumber,
    }

    switch item->Internal.getItemDcs {
    | None => {
        item->Internal.setItemDcs([dc])
        itemsWithDcs->Array.push(item)
      }
    | Some(dcs) => dcs->Array.push(dc)
    }
  }

  let promises = []
  for idx in 0 to itemsWithContractRegister->Array.length - 1 {
    let item = itemsWithContractRegister->Array.getUnsafe(idx)
    let eventItem = item->Internal.castUnsafeEventItem
    let contractRegister = switch eventItem {
    | {eventConfig: {contractRegister: Some(contractRegister)}} => contractRegister
    | {eventConfig: {contractRegister: None, name: eventName}} =>
      // Unexpected case, since we should pass only events with contract register to this function
      JsError.throwWithMessage("Contract register is not set for event " ++ eventName)
    }

    let errorMessage = "Event contractRegister failed, please fix the error to keep the indexer running smoothly"

    // Catch sync and async errors
    try {
      let params: ContractRegisterContext.contractRegisterParams = {
        item,
        onRegister,
        config,
        isResolved: false,
      }
      let result = contractRegister(ContractRegisterContext.getContractRegisterArgs(params))

      // Even though `contractRegister` always returns a promise,
      // in the ReScript type, but it might return a non-promise value for TS API.
      if result->Utils.Promise.isCatchable {
        promises->Array.push(
          result
          ->Promise.thenResolve(r => {
            params.isResolved = true
            r
          })
          ->Promise.catch(exn => {
            params.isResolved = true
            exn->ErrorHandling.mkLogAndRaise(~msg=errorMessage, ~logger=item->Logging.getItemLogger)
          }),
        )
      } else {
        params.isResolved = true
      }
    } catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(~msg=errorMessage, ~logger=item->Logging.getItemLogger)
    }
  }

  if promises->Utils.Array.notEmpty {
    let _ = await Promise.all(promises)
  }

  itemsWithDcs
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
    let chainState = state->IndexerState.getChainState(~chain)
    let {
      parsedQueueItems,
      latestFetchedBlockNumber,
      latestFetchedBlockTimestamp,
      stats,
      knownHeight,
      blockHashes,
      fromBlockQueried,
    } = response

    if knownHeight > (chainState->ChainState.fetchState).knownHeight {
      Prometheus.SourceHeight.set(
        ~blockNumber=knownHeight,
        ~chainId=(chainState->ChainState.chainConfig).id,
        // The knownHeight from response won't necessarily
        // belong to the currently active source.
        // But for simplicity, assume it does.
        ~sourceName=(chainState->ChainState.sourceManager->SourceManager.getActiveSource).name,
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
      chainState
      ->ChainState.reorgDetection
      ->ReorgDetection.registerReorgGuard(~blockHashes, ~knownHeight)

    let rollbackWithReorgDetectedBlockNumber = switch reorgResult {
    | ReorgDetected(reorgDetected) => {
        chainState
        ->ChainState.logger
        ->Logging.childInfo(
          reorgDetected->ReorgDetection.reorgDetectedToLogParams(
            ~shouldRollbackOnReorg=(state->IndexerState.config).shouldRollbackOnReorg,
          ),
        )
        Prometheus.ReorgCount.increment(~chain)
        Prometheus.ReorgDetectionBlockNumber.set(
          ~blockNumber=reorgDetected.scannedBlock.blockNumber,
          ~chain,
        )
        if (state->IndexerState.config).shouldRollbackOnReorg {
          Some(reorgDetected.scannedBlock.blockNumber)
        } else {
          None
        }
      }
    | NoReorg => None
    }

    switch rollbackWithReorgDetectedBlockNumber {
    | Some(reorgDetectedBlockNumber) =>
      switch state->IndexerState.rollbackState {
      | RollbackReady({eventsProcessedDiffByChain}) =>
        // Restore event counters for ALL chains, not just the reorg chain.
        // The previous rollback subtracted from all chains' counters,
        // but was never committed to DB. So we must undo the subtraction
        // for every chain before the new rollback subtracts again.
        state
        ->IndexerState.chainStates
        ->Utils.Dict.forEach(cs => {
          switch eventsProcessedDiffByChain->Utils.Dict.dangerouslyGetByIntNonOption(
            (cs->ChainState.chainConfig).id,
          ) {
          | Some(eventsProcessedDiff) =>
            // Since we detected a reorg, until rollback wasn't completed in the db
            // We return the events processed counter to the pre-rollback value,
            // to decrease it once more for the new rollback.
            cs->ChainState.setNumEventsProcessed(
              cs->ChainState.numEventsProcessed +. eventsProcessedDiff,
            )
          | None => ()
          }
        })
      | _ => ()
      }
      // TODO: It's not optimal to abort pending queries for all chains,
      // this is how it always worked, but we should consider a better approach.
      state
      ->IndexerState.chainStates
      ->Utils.Dict.forEach(cs => {
        cs->ChainState.setFetchState(cs->ChainState.fetchState->FetchState.resetPendingQueries)
      })
      state->IndexerState.beginReorg(~chain, ~blockNumber=reorgDetectedBlockNumber)
      // Advances synchronously to FindingReorgDepth, so a concurrent rollback
      // kick (eg from the processing loop quiescing) collapses into this one.
      scheduleRollback()
    | None =>
      chainState->ChainState.setReorgDetection(updatedReorgDetection)

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
        switch await runContractRegistersOrThrow(
          ~itemsWithContractRegister,
          ~config=state->IndexerState.config,
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
  let chainState = state->IndexerState.getChainState(~chain)
  let wasFetchingAtHead = chainState->ChainState.fetchState->FetchState.isFetchingAtHead

  chainState->ChainState.handleQueryResult(
    ~query,
    ~latestFetchedBlock,
    ~newItems,
    ~newItemsWithDcs,
    ~knownHeight,
  )

  // In auto-exit mode, set endBlock to the first event's block when events arrive.
  // Also update if a partition returns events at an earlier block than current endBlock.
  if state->IndexerState.exitAfterFirstEventBlock && newItems->Array.length > 0 {
    let firstEventBlock = newItems->Array.getUnsafe(0)->Internal.getItemBlockNumber
    let fetchState = chainState->ChainState.fetchState
    switch fetchState.endBlock {
    | None => chainState->ChainState.setFetchState({...fetchState, endBlock: Some(firstEventBlock)})
    | Some(currentEndBlock) if firstEventBlock < currentEndBlock =>
      chainState->ChainState.setFetchState({...fetchState, endBlock: Some(firstEventBlock)})
    | Some(_) => ()
    }
  }

  // Log the backfill→head transition once: this response brought the fetch
  // frontier to the head. Gated on !isReady so realtime re-catch-ups (a new
  // block arrives, gets fetched) don't spam the log after the chain is synced.
  if (
    !wasFetchingAtHead &&
    !(chainState->ChainState.isReady) &&
    chainState->ChainState.fetchState->FetchState.isFetchingAtHead
  ) {
    chainState->ChainState.logger->Logging.childInfo("All events have been fetched")
  }
}

let finishWaitingForNewBlock = (
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
    let chainState = state->IndexerState.getChainState(~chain)
    let updatedFetchState =
      chainState->ChainState.fetchState->FetchState.updateKnownHeight(~knownHeight)
    if updatedFetchState !== chainState->ChainState.fetchState {
      chainState->ChainState.setFetchState(updatedFetchState)
    }

    let isBelowReorgThreshold =
      !(state->IndexerState.isInReorgThreshold) &&
      (state->IndexerState.config).shouldRollbackOnReorg
    let shouldEnterReorgThreshold =
      isBelowReorgThreshold &&
      state
      ->IndexerState.chainStates
      ->Dict.valuesToArray
      ->Array.every(cs => {
        cs->ChainState.fetchState->FetchState.isReadyToEnterReorgThreshold
      })

    // Kick processing in case there are block handlers to run.
    if shouldEnterReorgThreshold {
      IndexerState.enterReorgThreshold(state)
      scheduleFetchAllChains()
    } else {
      scheduleFetchChain(chain)
    }
    scheduleProcessing()
  }

let checkAndFetchForChain = async (
  state: IndexerState.t,
  chain,
  ~stateId,
  ~scheduleFetchAllChains,
  ~scheduleFetchChain,
  ~scheduleProcessing,
  ~scheduleRollback,
) => {
  let chainState = state->IndexerState.getChainState(~chain)
  if !(state->IndexerState.isResolvingReorg) && !(state->IndexerState.isStopped) {
    let fetchState = chainState->ChainState.fetchState
    let isRealtime = state->IndexerState.isRealtime
    let sourceManager = chainState->ChainState.sourceManager

    // Only affects the WaitingForNewBlock branch of fetchNext, where
    // there's nothing to fetch. During backfill any such chain is idle.
    let reducedPolling = !isRealtime

    // Owns its error boundary: launch doesn't catch, so any failure here (the
    // query, response handling, or fetchNext itself) must stop the indexer.
    try {
      await sourceManager->SourceManager.fetchNext(
        ~fetchState,
        ~waitForNewBlock=(~knownHeight) =>
          sourceManager->SourceManager.waitForNewBlock(~knownHeight, ~isRealtime, ~reducedPolling),
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
            let response = await sourceManager->SourceManager.executeQuery(
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

let checkAndFetchAllChains = async (
  state: IndexerState.t,
  ~stateId,
  ~scheduleFetchAllChains,
  ~scheduleFetchChain,
  ~scheduleProcessing,
  ~scheduleRollback,
) => {
  // Iterate the state's chain states so we can construct tests that don't use
  // all chains
  let _ = await state
  ->IndexerState.chainStates
  ->Dict.valuesToArray
  ->Array.map(cs =>
    checkAndFetchForChain(
      state,
      ChainMap.Chain.makeUnsafe(~chainId=(cs->ChainState.chainConfig).id),
      ~stateId,
      ~scheduleFetchAllChains,
      ~scheduleFetchChain,
      ~scheduleProcessing,
      ~scheduleRollback,
    )
  )
  ->Promise.all
}
