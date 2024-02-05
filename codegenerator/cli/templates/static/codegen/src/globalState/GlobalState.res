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
type action =
  | HyperSyncBlockRangeResponse(chain, HyperSyncWorker.blockRangeFetchResponse)
  | SetFetcherCurrentBlockHeight(chain, int)
  | EventBatchProcessed(EventProcessing.loadResponse<unit>)
  | SetCurrentlyProcessing(bool)
  | SetCurrentlyFetchingBatch(chain, bool)
  | UpdateQueues(ChainMap.t<DynamicContractFetcher.t>, arbitraryEventQueue)

type queryChain = CheckAllChainsRoot | Chain(chain)
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

let handleHyperSyncBlockRangeResponse = (
  state,
  ~chain,
  ~response: HyperSyncWorker.blockRangeFetchResponse,
) => {
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
    contractAddressMapping,
  } = response

  chainFetcher.logger->Logging.childTrace({
    "message": "Finished page range",
    "fromBlock": fromBlockQueried,
    "toBlock": heighestQueriedBlockNumber,
    "number of logs": parsedQueueItems->Array.length,
    "stats": stats,
  })

  //TODO: Check reorg has occurred  here and action reorg if need be
  let {parentHash, lastBlockScannedData} = reorgGuard

  // lastBlockScannedData->checkHasReorgOccurred(~parentHash, ~currentHeight=currentBlockHeight)

  let updatedFetcher =
    chainFetcher.fetcher
    ->DynamicContractFetcher.update(
      ~latestFetchedBlockTimestamp,
      ~latestFetchedBlockNumber=heighestQueriedBlockNumber,
      ~fetchedEvents=parsedQueueItems->List.fromArray,
      ~id=fetcherId,
    )
    ->unwrapExn

  let updatedChainFetcher = {
    ...chainFetcher->updateChainFetcherCurrentBlockHeight(~currentBlockHeight),
    fetcher: updatedFetcher,
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
  | HyperSyncBlockRangeResponse(chain, response) =>
    state->handleHyperSyncBlockRangeResponse(~chain, ~response)
  | EventBatchProcessed({
      dynamicContractRegistrations: Some({registrationsReversed, unprocessedBatchReversed}),
    }) =>
    let updatedArbQueue =
      unprocessedBatchReversed
      ->List.reverse
      ->DynamicContractFetcher.mergeSortedList(~cmp=(a, b) => {
        a->EventUtils.getEventComparatorFromQueueItem <
          b->EventUtils.getEventComparatorFromQueueItem
      }, state.chainManager.arbitraryEventPriorityQueue)

    let nextTasks = [ProcessEventBatch, NextQuery(CheckAllChainsRoot)]

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

      let updatedFetcher =
        currentChainFetcher.fetcher->DynamicContractFetcher.registerDynamicContract(
          ~contractAddressMapping,
          ~registeringEventBlockNumber,
          ~registeringEventLogIndex,
        )

      let updatedChainFetcher = {...currentChainFetcher, fetcher: updatedFetcher}

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
  | UpdateQueues(fetchers, arbitraryEventPriorityQueue) =>
    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      {
        ...cf,
        fetcher: fetchers->ChainMap.get(chain),
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
      [NextQuery(CheckAllChainsRoot)],
    )
  }
}

let checkAndFetchForChain = (chain, ~state, ~dispatchAction) => {
  let {fetcher, chainWorker, logger, currentBlockHeight, isFetchingBatch} =
    state.chainManager.chainFetchers->ChainMap.get(chain)
  if (
    !isFetchingBatch &&
    fetcher->DynamicContractFetcher.isReadyForNextQuery(~maxQueueSize=state.maxPerChainQueueSize)
  ) {
    switch chainWorker.contents {
    | HyperSync(worker) =>
      let query = fetcher->DynamicContractFetcher.getNextQuery(~currentBlockHeight)

      dispatchAction(SetCurrentlyFetchingBatch(chain, true))
      let setCurrentBlockHeight = (~currentBlockHeight) =>
        dispatchAction(SetFetcherCurrentBlockHeight(chain, currentBlockHeight))
      worker
      ->HyperSyncWorker.fetchBlockRange(
        ~query,
        ~logger,
        ~currentBlockHeight,
        ~setCurrentBlockHeight,
      )
      ->Promise.thenResolve(res => dispatchAction(HyperSyncBlockRangeResponse(chain, res)))
      ->ignore
    | Rpc(_) | RawEvents(_) =>
      Js.Exn.raiseError("Currently unhandled rpc or raw events worker with hypersync query")
    }
  }
}

let taskReducer = (state: t, task: task, ~dispatchAction) => {
  switch task {
  | NextQuery(chainCheck) =>
    let fetchForChain = checkAndFetchForChain(~state, ~dispatchAction)

    switch chainCheck {
    | Chain(chain) => chain->fetchForChain
    | CheckAllChainsRoot => ChainMap.Chain.all->Array.forEach(fetchForChain)
    }
  | ProcessEventBatch =>
    if !state.currentlyProcessingBatch {
      dispatchAction(SetCurrentlyProcessing(true))
      switch state.chainManager->ChainManager.createBatch(~maxBatchSize=state.maxBatchSize) {
      | Some({batch, fetchers, arbitraryEventQueue}) =>
        dispatchAction(UpdateQueues(fetchers, arbitraryEventQueue))
        let inMemoryStore = IO.InMemoryStore.make()
        EventProcessing.processEventBatch(~eventBatch=batch, ~inMemoryStore, ~fetchers)
        ->Promise.thenResolve(res => dispatchAction(EventBatchProcessed(res)))
        ->ignore
      | None => dispatchAction(SetCurrentlyProcessing(false))
      }
    }
  }
}
