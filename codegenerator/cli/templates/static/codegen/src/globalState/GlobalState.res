let unwrapExn = res =>
  switch res {
  | Ok(v) => v
  | Error(exn) => exn->raise
  }

open Belt
type t = {
  chainManager: ChainManager.t,
  currentlyProcessingBatch: bool,
  maxBatchSize: int,
  maxPerChainQueueSize: int,
}
type chain = ChainMap.Chain.t
type arbitraryEventQueue = list<Types.eventBatchQueueItem>
type blockRangeFetchResponse = ChainWorkerTypes.blockRangeFetchResponse<
  HyperSyncWorker.t,
  RpcWorker.t,
>
type action =
  | BlockRangeResponse(chain, blockRangeFetchResponse)
  | SetFetcherCurrentBlockHeight(chain, int)
  | EventBatchProcessed(EventProcessing.loadResponse<unit>)
  | SetCurrentlyProcessing(bool)
  | SetCurrentlyFetchingBatch(chain, bool)
  | UpdateQueues(ChainMap.t<FetchState.t>, arbitraryEventQueue)

type queryChain = CheckAllChains | Chain(chain)
type task =
  | NextQuery(queryChain)
  | ProcessEventBatch

let updateChainFetcherCurrentBlockHeight = (chainFetcher: ChainFetcher.t, ~currentBlockHeight) => {
  if currentBlockHeight > chainFetcher.currentBlockHeight {
    //Don't await this set, it can happen in its own time
    DbFunctions.ChainMetadata.setChainMetadataRow(
      ~chainId=chainFetcher.chainConfig.chain->ChainMap.Chain.toChainId,
      ~startBlock=chainFetcher.chainConfig.startBlock,
      ~blockHeight=currentBlockHeight,
    )->ignore

    {...chainFetcher, currentBlockHeight}
  } else {
    chainFetcher
  }
}

let handleSetCurrentBlockHeight = (state, ~chain, ~currentBlockHeight) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let updatedFetcher = chainFetcher->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)
  let updatedFetchers = state.chainManager.chainFetchers->ChainMap.set(chain, updatedFetcher)
  let nextState = {...state, chainManager: {...state.chainManager, chainFetchers: updatedFetchers}}
  let nextTasks = []
  (nextState, nextTasks)
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
    fetcherId,
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
      ~id=fetcherId,
    )
    ->unwrapExn

  let updatedChainFetcher = {
    ...chainFetcher->updateChainFetcherCurrentBlockHeight(~currentBlockHeight),
    chainWorker: worker,
    fetchState: updatedFetchState,
    isFetchingBatch: false,
  }

  let updatedFetchers = state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher)

  let nextState = {
    ...state,
    chainManager: {...state.chainManager, chainFetchers: updatedFetchers},
  }

  (nextState, [ProcessEventBatch, NextQuery(Chain(chain))])
}

let actionReducer = (state: t, action: action) => {
  switch action {
  | SetFetcherCurrentBlockHeight(chain, currentBlockHeight) =>
    state->handleSetCurrentBlockHeight(~chain, ~currentBlockHeight)
  | BlockRangeResponse(chain, response) => state->handleBlockRangeResponse(~chain, ~response)
  | EventBatchProcessed({
      dynamicContractRegistrations: Some({registrationsReversed, unprocessedBatchReversed}),
    }) =>
    let updatedArbQueue =
      unprocessedBatchReversed->List.reverse->FetchState.mergeSortedList(~cmp=(a, b) => {
        a->EventUtils.getEventComparatorFromQueueItem <
          b->EventUtils.getEventComparatorFromQueueItem
      }, state.chainManager.arbitraryEventPriorityQueue)

    let nextTasks = [ProcessEventBatch, NextQuery(CheckAllChains)]

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
        chainFetchers: updatedChainFetchers,
        arbitraryEventPriorityQueue: updatedArbQueue,
      }

      {
        ...state,
        chainManager: updatedChainManager,
        currentlyProcessingBatch: false,
      }
    })

    (nextState, nextTasks)

  | EventBatchProcessed({dynamicContractRegistrations: None}) => (
      {...state, currentlyProcessingBatch: false},
      [ProcessEventBatch],
    )
  | SetCurrentlyProcessing(currentlyProcessingBatch) => ({...state, currentlyProcessingBatch}, [])
  | SetCurrentlyFetchingBatch(chain, isFetchingBatch) =>
    let currentChainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
    let chainFetchers =
      state.chainManager.chainFetchers->ChainMap.set(
        chain,
        {...currentChainFetcher, isFetchingBatch},
      )

    ({...state, chainManager: {...state.chainManager, chainFetchers}}, [])
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
          chainFetchers,
          arbitraryEventPriorityQueue,
        },
      },
      [NextQuery(CheckAllChains)],
    )
  }
}

let checkAndFetchForChain = (chain, ~state, ~dispatchAction) => {
  let {fetchState, chainWorker, logger, currentBlockHeight, isFetchingBatch} =
    state.chainManager.chainFetchers->ChainMap.get(chain)
  if (
    !isFetchingBatch &&
    fetchState->FetchState.isReadyForNextQuery(~maxQueueSize=state.maxPerChainQueueSize)
  ) {
    let query = fetchState->FetchState.getNextQuery(~currentBlockHeight)

    dispatchAction(SetCurrentlyFetchingBatch(chain, true))
    let setCurrentBlockHeight = currentBlockHeight =>
      dispatchAction(SetFetcherCurrentBlockHeight(chain, currentBlockHeight))

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

let taskReducer = (state: t, task: task, ~dispatchAction) => {
  switch task {
  | NextQuery(chainCheck) =>
    let fetchForChain = checkAndFetchForChain(~state, ~dispatchAction)

    switch chainCheck {
    | Chain(chain) => chain->fetchForChain
    | CheckAllChains => ChainMap.Chain.all->Array.forEach(fetchForChain)
    }
  | ProcessEventBatch =>
    if !state.currentlyProcessingBatch {
      dispatchAction(SetCurrentlyProcessing(true))
      switch state.chainManager->ChainManager.createBatch(~maxBatchSize=state.maxBatchSize) {
      | Some({batch, fetchStatesMap, arbitraryEventQueue}) =>
        dispatchAction(UpdateQueues(fetchStatesMap, arbitraryEventQueue))
        let checkContractIsRegistered = (~chain, ~contractAddress, ~contractName) => {
          let fetchState = fetchStatesMap->ChainMap.get(chain)
          fetchState->FetchState.checkContainsRegisteredContractAddress(
            ~contractAddress,
            ~contractName,
          )
        }
        let inMemoryStore = IO.InMemoryStore.make()
        EventProcessing.processEventBatch(
          ~eventBatch=batch,
          ~inMemoryStore,
          ~checkContractIsRegistered,
        )
        ->Promise.thenResolve(res => dispatchAction(EventBatchProcessed(res)))
        ->ignore
      | None => dispatchAction(SetCurrentlyProcessing(false))
      }
    }
  }
}
