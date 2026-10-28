// Fetch orchestration and query-response handling. Re-enters the loop only
// through the injected schedule* effects; everything else points at IndexerState
// (state + transitions) and leaf effect modules.

type partitionQueryResponse = {
  chainId: ChainId.t,
  response: Source.blockRangeFetchResponse,
  query: FetchState.query,
}

let hasContractRegister = (item: Internal.item) =>
  switch item {
  | Event({onEventRegistration: {contractRegister: Some(_)}}) => true
  | Event(_) | Block(_) | Transaction(_) => false
  }

let invokeContractRegister = (runtime: HandlerRuntime.t, item: Internal.item) => {
  let contractRegister = switch (item->Internal.castUnsafeEventItem).onEventRegistration {
  | {contractRegister: Some(contractRegister)} => contractRegister
  | {contractRegister: None, eventConfig: {name: eventName}} =>
    // Unexpected case, since we should pass only events with contract register to this function
    JsError.throwWithMessage("Contract register is not set for event " ++ eventName)
  }
  contractRegister({
    event: item->Ecosystem.getItemEvent(~ecosystem=runtime->HandlerRuntime.ecosystem),
    context: runtime.contractRegisterContext,
  })
}

let runContractRegistersOrThrow = async (
  ~itemsWithContractRegister: array<Internal.item>,
  ~runtime: HandlerRuntime.t,
  ~chainState: ChainState.t,
) => {
  // contractRegister handlers can read event.transaction and event.block, so
  // materialise the selected fields onto the payloads before running them. All
  // items belong to the chain being fetched, and both stores are the chain's
  // own, which this response's pages have already been merged into.
  await ChainState.materializePageItems(
    ~items=itemsWithContractRegister,
    ~transactionStore=chainState->ChainState.transactionStore,
    ~blockStore=chainState->ChainState.blockStore,
    ~shouldChecksum=chainState->ChainState.shouldChecksum,
  )

  // Every run of the response adds into the same registrations, in call order.
  let registrations: array<AddressStore.registration> = []
  let chainLogger = chainState->ChainState.logger
  let ecosystem = runtime->HandlerRuntime.ecosystem

  let _ = await itemsWithContractRegister
  ->Array.map(async item => {
    let run: RunScope.contractRegisterRun = {
      item,
      isResolved: false,
      chainLogger,
      ecosystem,
      registrations,
    }
    let scope = RunScope.ContractRegister(run)
    switch await RunScope.enter(scope, invokeContractRegister, runtime, item) {
    | exception exn =>
      scope->RunScope.resolve
      exn->ErrorHandling.mkLogAndRaise(
        ~msg="Event contractRegister failed, please fix the error to keep the indexer running smoothly",
        ~logger=run->RunScope.contractRegisterLogger,
      )
    | () => scope->RunScope.resolve
    }
  })
  ->Promise.all

  registrations
}

let rec onQueryResponse = async (
  state: IndexerState.t,
  {chainId, response, query}: partitionQueryResponse,
  ~runtime,
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
      stats,
      knownHeight,
    } = response

    chainState->ChainState.recordBlockRangeFetch(
      ~totalTimeElapsed=stats.totalTimeElapsed,
      ~parsingTimeElapsed=stats.parsingTimeElapsed->Option.getOr(0.),
      ~numEvents=parsedQueueItems->Array.length,
      ~blockRangeSize=latestFetchedBlockNumber - query.fromBlock + 1,
    )

    let numContractRegisterEvents =
      parsedQueueItems->Array.reduce(0, (count, item) =>
        item->hasContractRegister ? count + 1 : count
      )
    if numContractRegisterEvents === 0 {
      chainState
      ->ChainState.logger
      ->Logger.trace(
        "Finished querying",
        ~params={
          "partitionId": query.partitionId,
          "fromBlock": query.fromBlock,
          "toBlock": latestFetchedBlockNumber,
          "numEvents": parsedQueueItems->Array.length,
        },
      )
    } else {
      chainState
      ->ChainState.logger
      ->Logger.trace(
        "Finished querying",
        ~params={
          "partitionId": query.partitionId,
          "fromBlock": query.fromBlock,
          "toBlock": latestFetchedBlockNumber,
          "numEvents": parsedQueueItems->Array.length,
          "numContractRegisterEvents": numContractRegisterEvents,
        },
      )
    }

    let reorgResult = chainState->ChainState.registerReorgGuard(~blockStore, ~knownHeight)

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

        // Must agree with the `reportOnly` flag registerReorgGuard passed to
        // the merge: a discarded page (rollback mode) needs the rollback to
        // actually happen, or the stale stored hash re-reports forever.
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
    // No rollback: either the guard found no reorg, or it found one and this
    // chain only reports them. Either way the guard has merged the blocks, so
    // the transactions follow. A source that reads the chain store to decide
    // what to fetch leaves out what the store already holds, so its page alone
    // does not cover its own items — only the merged store does, and contract
    // registers read it below.
    | None =>
      switch transactionStore {
      | Some(page) => chainState->ChainState.transactionStore->TransactionStore.merge(page)
      | None => ()
      }

      // Over-fetched events (a merged partition returning an address before its
      // effectiveStartBlock, a wildcard param referencing an address registered
      // after the log's block, or a registration whose own start block is later
      // than its contract's) are already dropped by the source's native gates,
      // so everything here is indexable.
      let newItems = parsedQueueItems
      let itemsWithContractRegister = []
      for idx in 0 to newItems->Array.length - 1 {
        let item = newItems->Array.getUnsafe(idx)
        if item->hasContractRegister {
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
            ~latestFetchedBlock=latestFetchedBlockNumber,
            ~query,
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
          ~runtime,
          ~chainState,
        ) {
        | exception exn =>
          IndexerState.errorExit(
            state,
            exn->ErrorHandling.make(~logger=chainState->ChainState.logger),
          )
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
) => {
  let chainState = state->IndexerState.getChainState(~chainId)

  chainState->ChainState.handleQueryResult(
    ~query,
    ~latestFetchedBlock,
    ~newItems,
    ~newRegistrations,
    ~knownHeight,
  )

  // In auto-exit mode, set endBlock to the first event's block when events arrive.
  if state->IndexerState.exitAfterFirstEventBlock {
    switch newItems->Array.find(item =>
      switch item {
      | Internal.Event(_) | Transaction(_) => true
      | Block(_) => false
      }
    ) {
    | Some(item) =>
      chainState->ChainState.setEndBlockToFirstEvent(~blockNumber=item->Internal.getItemBlockNumber)
    | None => ()
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
  chainId,
  ~runtime,
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
            let response = await sourceManager->SourceManager.executeQuery(
              ~query,
              ~knownHeight=chainState->ChainState.knownHeight,
              ~isRealtime,
              ~reorgableFrom=chainState->ChainState.reorgableFrom(~isRealtime),
            )
            await onQueryResponse(
              state,
              {chainId, response, query},
              ~runtime,
              ~stateId,
              ~scheduleFetch,
              ~scheduleProcessing,
              ~scheduleRollback,
            )
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
