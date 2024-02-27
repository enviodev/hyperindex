open Belt
type t = {
  chainManager: ChainManager.t,
  currentlyProcessingBatch: bool,
  maxBatchSize: int,
  maxPerChainQueueSize: int,
  indexerStartTime: Js.Date.t,
}
type chain = ChainMap.Chain.t
type arbitraryEventQueue = list<Types.eventBatchQueueItem>
type blockRangeFetchResponse = ChainWorkerTypes.blockRangeFetchResponse<
  HyperSyncWorker.t,
  RpcWorker.t,
>

type action =
  | BlockRangeResponse(chain, blockRangeFetchResponse)
  | SetFetchStateCurrentBlockHeight(chain, int)
  | EventBatchProcessed(EventProcessing.loadResponse<EventProcessing.EventsProcessed.t>)
  | SetCurrentlyProcessing(bool)
  | SetCurrentlyFetchingBatch(chain, bool)
  | SetFetchState(chain, FetchState.t)
  | SetIsFetchingAtHead(chain, bool)
  | UpdateQueues(ChainMap.t<FetchState.t>, arbitraryEventQueue)
  | ErrorExit(ErrorHandling.t)

type queryChain = CheckAllChains | Chain(chain)
type task =
  | NextQuery(queryChain)
  | ProcessEventBatch
  | UpdateChainMetaData

let updateChainFetcherCurrentBlockHeight = (chainFetcher: ChainFetcher.t, ~currentBlockHeight) => {
  if currentBlockHeight > chainFetcher.currentBlockHeight {
    Prometheus.setSourceChainHeight(
      ~blockNumber=currentBlockHeight,
      ~chain=chainFetcher.chainConfig.chain,
    )
    {...chainFetcher, currentBlockHeight}
  } else {
    chainFetcher
  }
}

let updateChainMetadataTable = async (cm: ChainManager.t) => {
  let chainMetadataArray: array<DbFunctions.ChainMetadata.chainMetadata> =
    cm.chainFetchers
    ->ChainMap.values
    ->Belt.Array.map(cf => {
      let chainMetadata: DbFunctions.ChainMetadata.chainMetadata = {
        chainId: cf.chainConfig.chain->ChainMap.Chain.toChainId,
        startBlock: cf.chainConfig.startBlock,
        blockHeight: cf.currentBlockHeight,
        //optional fields
        firstEventBlockNumber: cf.firstEventBlockNumber, //this is already optional
        latestProcessedBlock: cf.latestProcessedBlock, // this is already optional
        numEventsProcessed: Some(cf.numEventsProcessed),
      }
      chainMetadata
    })
  //Don't await this set, it can happen in its own time
  await DbFunctions.ChainMetadata.batchSetChainMetadataRow(~chainMetadataArray)
}

let handleSetCurrentBlockHeight = (state, ~chain, ~currentBlockHeight) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let updatedFetcher = chainFetcher->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)
  let updatedFetchers = state.chainManager.chainFetchers->ChainMap.set(chain, updatedFetcher)
  let nextState = {...state, chainManager: {...state.chainManager, chainFetchers: updatedFetchers}}
  let nextTasks = [NextQuery(Chain(chain))]
  (nextState, nextTasks)
}

let updateLatestProcessedBlocks = (
  ~state: t,
  ~latestProcessedBlocks: EventProcessing.EventsProcessed.t,
) => {
  {
    ...state,
    chainManager: {
      ...state.chainManager,
      chainFetchers: state.chainManager.chainFetchers->ChainMap.map(cf => {
        let chain = cf.chainConfig.chain
        let {latestProcessedBlock, numEventsProcessed} = latestProcessedBlocks->ChainMap.get(chain)

        let hasArbQueueEvents =
          state.chainManager.arbitraryEventPriorityQueue
          ->ChainManager.getFirstArbitraryEventsItemForChain(~chain)
          ->Option.isSome //TODO this is more expensive than it needs to be
        let fetchState = cf.fetchState
        let queueSize = fetchState->FetchState.queueSize

        let hasNoMoreEventsToProcess = !hasArbQueueEvents && queueSize == 0
        let latestProcessedBlock = if hasNoMoreEventsToProcess {
          fetchState->FetchState.getLatestFullyFetchedBlock->Some
        } else {
          latestProcessedBlock
        }

        let timestampCaughtUpToHead =
          cf.timestampCaughtUpToHead->Option.isNone &&
          // don't reset this once it's initially set
          hasNoMoreEventsToProcess &&
          cf.isFetchingAtHead
            ? Js.Date.make()->Some
            : None
        {
          ...cf,
          latestProcessedBlock,
          numEventsProcessed,
          timestampCaughtUpToHead,
        }
      }),
    },
  }
}

let handleBlockRangeResponse = (state, ~chain, ~response: blockRangeFetchResponse) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let {
    parsedQueueItems,
    heighestQueriedBlockNumber,
    stats,
    currentBlockHeight,
    reorgGuard,
    fromBlockQueried,
    fetchStateRegisterId,
    latestFetchedBlockTimestamp,
    worker,
  } = response

  chainFetcher.logger->Logging.childTrace({
    "message": "Finished page range",
    "fromBlock": fromBlockQueried,
    "toBlock": heighestQueriedBlockNumber,
    "number of logs": parsedQueueItems->Array.length,
    "stats": stats,
  })

  //TODO: Check reorg has occurred  here and action reorg if need be
  let {parentHash: _, lastBlockScannedData: _} = reorgGuard

  // lastBlockScannedData->checkHasReorgOccurred(~parentHash, ~currentHeight=currentBlockHeight)

  let updatedFetchState =
    chainFetcher.fetchState
    ->FetchState.update(
      ~latestFetchedBlockTimestamp,
      ~latestFetchedBlockNumber=heighestQueriedBlockNumber,
      ~fetchedEvents=parsedQueueItems->List.fromArray,
      ~id=fetchStateRegisterId,
    )
    ->Utils.unwrapResultExn
  let chainFetcher = chainFetcher->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)
  let firstEventBlockNumber = switch parsedQueueItems[0] {
  | Some(item) if chainFetcher.firstEventBlockNumber->Option.isNone => item.blockNumber->Some
  | _ => chainFetcher.firstEventBlockNumber
  }

  let hasArbQueueEvents =
    state.chainManager.arbitraryEventPriorityQueue
    ->ChainManager.getFirstArbitraryEventsItemForChain(~chain)
    ->Option.isSome //TODO this is more expensive than it needs to be

  let queueSize = updatedFetchState->FetchState.queueSize

  let hasNoMoreEventsToProcess = !hasArbQueueEvents && queueSize == 0
  let latestProcessedBlock = if hasNoMoreEventsToProcess {
    updatedFetchState->FetchState.getLatestFullyFetchedBlock->Some
  } else {
    chainFetcher.latestProcessedBlock
  }

  let timestampCaughtUpToHead =
    chainFetcher.timestampCaughtUpToHead->Option.isNone && // don't reset this once it's initially set
    hasNoMoreEventsToProcess &&
    chainFetcher.isFetchingAtHead
      ? Js.Date.make()->Some
      : chainFetcher.timestampCaughtUpToHead

  let updatedChainFetcher = {
    ...chainFetcher,
    chainWorker: worker,
    fetchState: updatedFetchState,
    isFetchingBatch: false,
    firstEventBlockNumber,
    latestProcessedBlock,
    timestampCaughtUpToHead,
  }

  let updatedFetchers = state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher)

  let nextState = {
    ...state,
    chainManager: {...state.chainManager, chainFetchers: updatedFetchers},
  }

  Prometheus.setFetchedEventsUntilHeight(~blockNumber=response.heighestQueriedBlockNumber, ~chain)

  (nextState, [UpdateChainMetaData, ProcessEventBatch, NextQuery(Chain(chain))])
}

let updateChainFetcher = (chainFetcherUpdate, ~state, ~chain) => {
  (
    {
      ...state,
      chainManager: {
        ...state.chainManager,
        chainFetchers: state.chainManager.chainFetchers->ChainMap.update(chain, chainFetcherUpdate),
      },
    },
    [],
  )
}

let actionReducer = (state: t, action: action) => {
  switch action {
  | SetFetchStateCurrentBlockHeight(chain, currentBlockHeight) =>
    state->handleSetCurrentBlockHeight(~chain, ~currentBlockHeight)
  | BlockRangeResponse(chain, response) => state->handleBlockRangeResponse(~chain, ~response)
  | EventBatchProcessed({
      val,
      dynamicContractRegistrations: Some({registrationsReversed, unprocessedBatchReversed}),
    }) =>
    let updatedArbQueue =
      unprocessedBatchReversed->List.reverse->FetchState.mergeSortedList(~cmp=(a, b) => {
        a->EventUtils.getEventComparatorFromQueueItem <
          b->EventUtils.getEventComparatorFromQueueItem
      }, state.chainManager.arbitraryEventPriorityQueue)

    let nextTasks = [UpdateChainMetaData, ProcessEventBatch, NextQuery(CheckAllChains)]

    let nextState = registrationsReversed->List.reduce(state, (state, registration) => {
      let {
        registeringEventBlockNumber,
        registeringEventLogIndex,
        registeringEventChain,
        dynamicContracts,
      } = registration

      let contractAddressMapping =
        dynamicContracts
        ->Array.map(d => (d.contractAddress, d.contractType))
        ->ContractAddressingMap.fromArray

      let currentChainFetcher =
        state.chainManager.chainFetchers->ChainMap.get(registeringEventChain)

      let updatedFetchState =
        currentChainFetcher.fetchState->FetchState.registerDynamicContract(
          ~contractAddressMapping,
          ~registeringEventBlockNumber,
          ~registeringEventLogIndex,
        )

      let updatedChainFetcher = {...currentChainFetcher, fetchState: updatedFetchState}

      let updatedChainFetchers =
        state.chainManager.chainFetchers->ChainMap.set(registeringEventChain, updatedChainFetcher)

      let updatedChainManager: ChainManager.t = {
        ...state.chainManager,
        chainFetchers: updatedChainFetchers,
        arbitraryEventPriorityQueue: updatedArbQueue,
      }

      {
        ...state,
        chainManager: updatedChainManager,
        currentlyProcessingBatch: false,
      }
    })

    // This ONLY updates the metrics - no logic is performed.
    nextState.chainManager.chainFetchers
    ->ChainMap.entries
    ->Array.forEach(((chain, chainFetcher)) => {
      let highestFetchedBlockOnChain =
        chainFetcher.fetchState->FetchState.getLatestFullyFetchedBlock

      Prometheus.setFetchedEventsUntilHeight(~blockNumber=highestFetchedBlockOnChain, ~chain)
    })
    let nextState = updateLatestProcessedBlocks(~state=nextState, ~latestProcessedBlocks=val)
    (nextState, nextTasks)

  | EventBatchProcessed({val, dynamicContractRegistrations: None}) =>
    let nextState = updateLatestProcessedBlocks(~state, ~latestProcessedBlocks=val)
    ({...nextState, currentlyProcessingBatch: false}, [UpdateChainMetaData, ProcessEventBatch])
  | SetCurrentlyProcessing(currentlyProcessingBatch) => ({...state, currentlyProcessingBatch}, [])
  | SetIsFetchingAtHead(chain, isFetchingAtHead) =>
    updateChainFetcher(
      currentChainFetcher => {...currentChainFetcher, isFetchingAtHead},
      ~chain,
      ~state,
    )
  | SetCurrentlyFetchingBatch(chain, isFetchingBatch) =>
    updateChainFetcher(
      currentChainFetcher => {...currentChainFetcher, isFetchingBatch},
      ~chain,
      ~state,
    )
  | SetFetchState(chain, fetchState) =>
    updateChainFetcher(currentChainFetcher => {...currentChainFetcher, fetchState}, ~chain, ~state)
  | UpdateQueues(fetchStatesMap, arbitraryEventPriorityQueue) =>
    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      {
        ...cf,
        fetchState: fetchStatesMap->ChainMap.get(chain),
      }
    })

    (
      {
        ...state,
        chainManager: {
          ...state.chainManager,
          chainFetchers,
          arbitraryEventPriorityQueue,
        },
      },
      [NextQuery(CheckAllChains)],
    )
  | ErrorExit(errHandler) =>
    errHandler->ErrorHandling.log
    errHandler->ErrorHandling.raiseExn
  }
}

let checkAndFetchForChain = (chain, ~state, ~dispatchAction) => {
  let {fetchState, chainWorker, logger, currentBlockHeight, isFetchingBatch, isFetchingAtHead} =
    state.chainManager.chainFetchers->ChainMap.get(chain)

  if (
    !isFetchingBatch &&
    fetchState->FetchState.isReadyForNextQuery(~maxQueueSize=state.maxPerChainQueueSize)
  ) {
    let (nextQuery, nextStateIfChangeRequired) =
      fetchState->FetchState.getNextQuery(~currentBlockHeight)->Utils.unwrapResultExn

    switch nextStateIfChangeRequired {
    | Some(nextFetchState) => dispatchAction(SetFetchState(chain, nextFetchState))
    | None => ()
    }

    let setCurrentBlockHeight = currentBlockHeight =>
      dispatchAction(SetFetchStateCurrentBlockHeight(chain, currentBlockHeight))

    switch nextQuery {
    | WaitForNewBlock =>
      if !isFetchingAtHead && currentBlockHeight != 0 && fetchState->FetchState.queueSize == 0 {
        logger->Logging.childInfo(
          "All events have been fetched, they should finish processing the handlers soon.",
        )
        dispatchAction(SetIsFetchingAtHead(chain, true))
      }
      logger->Logging.childTrace("Waiting for new blocks")
      let compose = async (worker, waitForBlockGreaterThanCurrentHeight) => {
        let newHeight =
          await worker->waitForBlockGreaterThanCurrentHeight(~currentBlockHeight, ~logger)
        setCurrentBlockHeight(newHeight)
      }
      switch chainWorker {
      | HyperSync(w) => compose(w, HyperSyncWorker.waitForBlockGreaterThanCurrentHeight)
      | Rpc(w) => compose(w, RpcWorker.waitForBlockGreaterThanCurrentHeight)
      }->ignore
    | NextQuery(query) =>
      dispatchAction(SetCurrentlyFetchingBatch(chain, true))

      let compose = (worker, fetchBlockRange) => {
        worker
        ->fetchBlockRange(~query, ~logger, ~currentBlockHeight, ~setCurrentBlockHeight)
        ->Promise.thenResolve(res => dispatchAction(BlockRangeResponse(chain, res)))
        ->ignore
      }

      switch chainWorker {
      | HyperSync(worker) => compose(worker, HyperSyncWorker.fetchBlockRange)
      | Rpc(worker) => compose(worker, RpcWorker.fetchBlockRange)
      }
    }
  }
}

let taskReducer = (state: t, task: task, ~dispatchAction) => {
  switch task {
  | UpdateChainMetaData => updateChainMetadataTable(state.chainManager)->ignore
  | NextQuery(chainCheck) =>
    let fetchForChain = checkAndFetchForChain(~state, ~dispatchAction)

    switch chainCheck {
    | Chain(chain) => chain->fetchForChain
    | CheckAllChains =>
      //Mapping from the states chainManager so we can construct tests that don't use
      //all chains
      state.chainManager.chainFetchers->ChainMap.keys->Array.forEach(fetchForChain)
    }
  | ProcessEventBatch =>
    if !state.currentlyProcessingBatch {
      switch state.chainManager->ChainManager.createBatch(~maxBatchSize=state.maxBatchSize) {
      | Some({batch, fetchStatesMap, arbitraryEventQueue}) =>
        dispatchAction(SetCurrentlyProcessing(true))
        dispatchAction(UpdateQueues(fetchStatesMap, arbitraryEventQueue))

        // This function is used to ensure that registering an alreday existing contract as a dynamic contract can't cause issues.
        let checkContractIsRegistered = (~chain, ~contractAddress, ~contractName) => {
          let fetchState = fetchStatesMap->ChainMap.get(chain)
          fetchState->FetchState.checkContainsRegisteredContractAddress(
            ~contractAddress,
            ~contractName,
          )
        }
        let latestProcessedBlocks = EventProcessing.EventsProcessed.makeFromChainManager(
          state.chainManager,
        )
        let inMemoryStore = IO.InMemoryStore.make()
        EventProcessing.processEventBatch(
          ~eventBatch=batch,
          ~inMemoryStore,
          ~checkContractIsRegistered,
          ~latestProcessedBlocks,
        )
        ->Promise.thenResolve(res =>
          switch res {
          | Ok(loadRes) => dispatchAction(EventBatchProcessed(loadRes))
          | Error(errHandler) => dispatchAction(ErrorExit(errHandler))
          }
        )
        ->Promise.catch(exn => {
          //All casese should be handled/caught before this with better user messaging.
          //This is just a safety in case something unexpected happens
          let errHandler =
            exn->ErrorHandling.make(~msg="A top level unexpected error occurred during processing")
          dispatchAction(ErrorExit(errHandler))
          Promise.reject(exn)
        })
        ->ignore
      | None => ()
      }
    }
  }
}
