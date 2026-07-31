// Fetch orchestration and query-response handling. Re-enters the loop only
// through the injected schedule* effects; everything else points at IndexerState
// (state + transitions) and leaf effect modules.

type partitionQueryResponse = {
  chainId: ChainId.t,
  response: Source.blockRangeFetchResponse,
  query: FetchState.query,
}

let runContractRegistersOrThrow = async (
  ~itemsWithContractRegister: array<Internal.item>,
  ~config: Config.t,
  ~transactionStore: option<TransactionStore.t>,
  ~blockStore: option<BlockStore.t>,
) => {
  // contractRegister handlers can read event.transaction and event.block, so
  // materialise the selected fields onto the payloads before running them. All
  // items belong to the chain being fetched, hence its single page stores.
  await ChainState.materializePageItems(
    ~items=itemsWithContractRegister,
    ~transactionStore,
    ~blockStore,
    ~ecosystem=config.ecosystem.name,
  )

  let registrations: array<AddressStore.registration> = []

  let onRegister = (~item: Internal.item, ~contractAddress, ~contractName) => {
    let eventItem = item->Internal.castUnsafeEventItem
    registrations->Array.push({
      address: contractAddress,
      contractName,
      registrationBlock: eventItem.blockNumber,
    })
  }

  let promises = []
  for idx in 0 to itemsWithContractRegister->Array.length - 1 {
    let item = itemsWithContractRegister->Array.getUnsafe(idx)
    let eventItem = item->Internal.castUnsafeEventItem
    let contractRegister = switch eventItem.onEventRegistration {
    | {contractRegister: Some(contractRegister)} => contractRegister
    | {contractRegister: None, eventConfig: {name: eventName}} =>
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
            exn->ErrorHandling.mkLogAndRaise(
              ~msg=errorMessage,
              ~logger=Ecosystem.getItemLogger(item, ~ecosystem=config.ecosystem),
            )
          }),
        )
      } else {
        params.isResolved = true
      }
    } catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~msg=errorMessage,
        ~logger=Ecosystem.getItemLogger(item, ~ecosystem=config.ecosystem),
      )
    }
  }

  if promises->Utils.Array.notEmpty {
    let _ = await Promise.all(promises)
  }

  registrations
}

let rec onQueryResponse = async (
  state: IndexerState.t,
  {chainId, response, query}: partitionQueryResponse,
  ~stateId,
  ~scheduleFetch,
  ~scheduleProcessing,
  ~scheduleRollback,
) =>
  if state->IndexerState.isStale(~stateId) {
    ()
  } else {
    let chainState = state->IndexerState.getChainState(~chainId)
    let {
      parsedQueueItems,
      transactionStore,
      blockStore,
      latestFetchedBlockNumber,
      latestFetchedBlockTimestamp,
      stats,
      knownHeight,
      blockHashes,
      fromBlockQueried,
    } = response

    chainState->ChainState.recordBlockRangeFetch(
      ~totalTimeElapsed=stats.totalTimeElapsed,
      ~parsingTimeElapsed=stats.parsingTimeElapsed->Option.getOr(0.),
      ~numEvents=parsedQueueItems->Array.length,
      ~blockRangeSize=latestFetchedBlockNumber - fromBlockQueried + 1,
    )

    let numContractRegisterEvents = parsedQueueItems->Array.reduce(0, (count, item) => {
      let eventItem = item->Internal.castUnsafeEventItem
      eventItem.onEventRegistration.contractRegister !== None ? count + 1 : count
    })
    if numContractRegisterEvents === 0 {
      Logging.trace({
        "msg": "Finished querying",
        "chainId": chainId,
        "partitionId": query.partitionId,
        "fromBlock": fromBlockQueried,
        "toBlock": latestFetchedBlockNumber,
        "numEvents": parsedQueueItems->Array.length,
      })
    } else {
      Logging.trace({
        "msg": "Finished querying",
        "chainId": chainId,
        "partitionId": query.partitionId,
        "fromBlock": fromBlockQueried,
        "toBlock": latestFetchedBlockNumber,
        "numEvents": parsedQueueItems->Array.length,
        "numContractRegisterEvents": numContractRegisterEvents,
      })
    }

    let reorgResult = chainState->ChainState.registerReorgGuard(~blockHashes, ~knownHeight)

    let rollbackWithReorgDetectedBlockNumber = switch reorgResult {
    | ReorgDetected(reorgDetected) => {
        chainState
        ->ChainState.logger
        ->Logging.childInfo(
          reorgDetected->ReorgDetection.reorgDetectedToLogParams(
            ~shouldRollbackOnReorg=(state->IndexerState.config).shouldRollbackOnReorg,
          ),
        )
        chainState->ChainState.recordReorgDetected(
          ~blockNumber=reorgDetected.scannedBlock.blockNumber,
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
    | None =>
      // Over-fetched events (a merged partition returning an address before its
      // effectiveStartBlock, a wildcard param referencing an address registered
      // after the log's block, or a registration whose own start block is later
      // than its contract's) are already dropped by the source's native gates,
      // so everything here is indexable.
      let newItems = parsedQueueItems
      let itemsWithContractRegister = []
      for idx in 0 to newItems->Array.length - 1 {
        let item = newItems->Array.getUnsafe(idx)
        let eventItem = item->Internal.castUnsafeEventItem
        if eventItem.onEventRegistration.contractRegister !== None {
          itemsWithContractRegister->Array.push(item)
        }
      }

      // Re-check staleness: contract registration is async, so the chain state
      // may have rolled back by the time we apply the fetched items.
      let proceed = (~newRegistrations) =>
        if !(state->IndexerState.isStale(~stateId)) {
          applyQueryResponse(
            state,
            ~chainId,
            ~newItems,
            ~newRegistrations,
            ~knownHeight,
            ~latestFetchedBlock={
              FetchState.blockNumber: latestFetchedBlockNumber,
              blockTimestamp: latestFetchedBlockTimestamp,
            },
            ~query,
            ~transactionStore,
            ~blockStore,
          )
          ChainMetadata.stage(state)
          scheduleFetch()
          scheduleProcessing()
        }

      switch itemsWithContractRegister {
      | [] => proceed(~newRegistrations=[])
      | _ =>
        switch await runContractRegistersOrThrow(
          ~itemsWithContractRegister,
          ~config=state->IndexerState.config,
          ~transactionStore,
          ~blockStore,
        ) {
        | exception exn => IndexerState.errorExit(state, exn->ErrorHandling.make)
        | newRegistrations => proceed(~newRegistrations)
        }
      }
    }
  }

and applyQueryResponse = (
  state: IndexerState.t,
  ~chainId,
  ~newItems,
  ~newRegistrations,
  ~knownHeight,
  ~latestFetchedBlock,
  ~query,
  ~transactionStore,
  ~blockStore,
) => {
  let chainState = state->IndexerState.getChainState(~chainId)
  let wasFetchingAtHead = chainState->ChainState.isFetchingAtHead

  chainState->ChainState.handleQueryResult(
    ~query,
    ~latestFetchedBlock,
    ~newItems,
    ~newRegistrations,
    ~knownHeight,
    ~transactionStore,
    ~blockStore,
  )

  // In auto-exit mode, set endBlock to the first event's block when events arrive.
  if state->IndexerState.exitAfterFirstEventBlock && newItems->Array.length > 0 {
    chainState->ChainState.setEndBlockToFirstEvent(
      ~blockNumber=newItems->Array.getUnsafe(0)->Internal.getItemBlockNumber,
    )
  }

  // Log the backfill→head transition once: this response brought the fetch
  // frontier to the head. Gated on !isReady so realtime re-catch-ups (a new
  // block arrives, gets fetched) don't spam the log after the chain is synced.
  if (
    !wasFetchingAtHead &&
    !(chainState->ChainState.isReady) &&
    chainState->ChainState.isFetchingAtHead
  ) {
    chainState->ChainState.logger->Logging.childInfo("All events have been fetched")
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
) => {
  let chainState = state->IndexerState.getChainState(~chainId)
  if !(state->IndexerState.isResolvingReorg) && !(state->IndexerState.isStopped) {
    let isRealtime = state->IndexerState.isRealtime
    let sourceManager = chainState->ChainState.sourceManager

    // Only affects the WaitingForNewBlock branch of dispatch, where
    // there's nothing to fetch. During backfill any such chain is idle.
    let reducedPolling = !isRealtime

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
            let response = await sourceManager->SourceManager.executeQuery(
              ~query,
              ~knownHeight=chainState->ChainState.knownHeight,
              ~isRealtime,
            )
            await onQueryResponse(
              state,
              {chainId, response, query},
              ~stateId,
              ~scheduleFetch,
              ~scheduleProcessing,
              ~scheduleRollback,
            )
          } catch {
          | exn => IndexerState.errorExit(state, exn->ErrorHandling.make)
          }
        },
        ~action,
        ~stateId,
      )
    } catch {
    | exn =>
      IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=IndexerState.unexpectedErrorMsg))
    }
  }
}
