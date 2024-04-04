open Belt
type t = {
  chainManager: ChainManager.t,
  currentlyProcessingBatch: bool,
  maxBatchSize: int,
  maxPerChainQueueSize: int,
  indexerStartTime: Js.Date.t,
  saveRawEvents: bool,
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
  | UpdateQueues(ChainMap.t<FetchState.t>, arbitraryEventQueue)
  | SetSyncedChains
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

/**
Takes in a chain manager and sets all chains timestamp caught up to head
when valid state lines up and returns an updated chain manager
*/
let checkAndSetSyncedChains = (~nextQueueItemIsKnownNone=false, chainManager: ChainManager.t) => {
  let nextQueueItemIsNone =
    nextQueueItemIsKnownNone || chainManager->ChainManager.peakNextBatchItem->Option.isNone

  let allChainsAtHead =
    chainManager.chainFetchers
    ->ChainMap.values
    ->Array.reduce(true, (accum, cf) => cf.isFetchingAtHead && accum)

  //Update the timestampCaughtUpToHead values
  let chainFetchers = chainManager.chainFetchers->ChainMap.map(cf => {
    //Only calculate and set timestampCaughtUpToHead if chain fetcher is at the head and
    //its not already set
    if cf.timestampCaughtUpToHead->Option.isNone && cf.isFetchingAtHead {
      //CASE1
      //All chains are caught up to head chainManager queue returns None
      //Meaning we are busy synchronizing chains at the head
      if nextQueueItemIsNone && allChainsAtHead {
        {
          ...cf,
          timestampCaughtUpToHead: Js.Date.make()->Some,
        }
      } else {
        //CASE2 -> Only calculate if case1 fails
        //All events have been processed on the chain fetchers queue
        //Other chains may be busy syncing
        let hasArbQueueEvents =
          chainManager.arbitraryEventPriorityQueue
          ->ChainManager.getFirstArbitraryEventsItemForChain(~chain=cf.chainConfig.chain)
          ->Option.isSome //TODO this is more expensive than it needs to be
        let queueSize = cf.fetchState->FetchState.queueSize
        let hasNoMoreEventsToProcess = !hasArbQueueEvents && queueSize == 0

        if hasNoMoreEventsToProcess {
          {
            ...cf,
            timestampCaughtUpToHead: Js.Date.make()->Some,
          }
        } else {
          //Default to just returning cf
          cf
        }
      }
    } else {
      //Default to just returning cf
      cf
    }
  })

  {
    ...chainManager,
    chainFetchers,
  }
}

let updateLatestProcessedBlocks = (
  ~state: t,
  ~latestProcessedBlocks: EventProcessing.EventsProcessed.t,
) => {
  let chainManager = {
    ...state.chainManager,
    chainFetchers: state.chainManager.chainFetchers->ChainMap.map(cf => {
      let {chainConfig: {chain}, fetchState} = cf
      let {numEventsProcessed, latestProcessedBlock} = latestProcessedBlocks->ChainMap.get(chain)

      let hasArbQueueEvents =
        state.chainManager.arbitraryEventPriorityQueue
        ->ChainManager.getFirstArbitraryEventsItemForChain(~chain)
        ->Option.isSome //TODO this is more expensive than it needs to be
      let queueSize = fetchState->FetchState.queueSize

      let hasNoMoreEventsToProcess = !hasArbQueueEvents && queueSize == 0

      let latestProcessedBlock = if hasNoMoreEventsToProcess {
        fetchState->FetchState.getLatestFullyFetchedBlock->Some
      } else {
        latestProcessedBlock
      }

      {
        ...cf,
        latestProcessedBlock,
        numEventsProcessed,
      }
    }),
  }
  {
    ...state,
    chainManager: chainManager->checkAndSetSyncedChains,
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

  let isFetchingAtHead = if currentBlockHeight <= heighestQueriedBlockNumber {
    if !chainFetcher.isFetchingAtHead {
      chainFetcher.logger->Logging.childInfo(
        "All events have been fetched, they should finish processing the handlers soon.",
      )
    }
    true
  } else {
    chainFetcher.isFetchingAtHead
  }

  let updatedChainFetcher = {
    ...chainFetcher,
    chainWorker: worker,
    fetchState: updatedFetchState,
    isFetchingBatch: false,
    firstEventBlockNumber,
    latestProcessedBlock,
    isFetchingAtHead,
    numBatchesFetched: chainFetcher.numBatchesFetched + 1,
  }

  let chainManager = {
    ...state.chainManager,
    chainFetchers: state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher),
  }

  let nextState = {
    ...state,
    chainManager,
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

      let updatedChainFetcher = {
        ...currentChainFetcher,
        fetchState: updatedFetchState,
        //New contracts to fetch so no longer fetching at head
        //and reset ts caught up to head
        isFetchingAtHead: false,
        timestampCaughtUpToHead: None,
      }

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
  | SetCurrentlyFetchingBatch(chain, isFetchingBatch) =>
    updateChainFetcher(
      currentChainFetcher => {...currentChainFetcher, isFetchingBatch},
      ~chain,
      ~state,
    )
  | SetFetchState(chain, fetchState) =>
    updateChainFetcher(currentChainFetcher => {...currentChainFetcher, fetchState}, ~chain, ~state)
  | SetSyncedChains => (
      {
        ...state,
        chainManager: state.chainManager->checkAndSetSyncedChains(~nextQueueItemIsKnownNone=true),
      },
      [],
    )
  | UpdateQueues(fetchStatesMap, arbitraryEventPriorityQueue) =>
    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      {
        ...cf,
        fetchState: fetchStatesMap->ChainMap.get(chain),
      }
    })

    let chainManager = {
      ...state.chainManager,
      chainFetchers,
      arbitraryEventPriorityQueue,
    }

    (
      {
        ...state,
        chainManager,
      },
      [NextQuery(CheckAllChains)],
    )
  | ErrorExit(errHandler) =>
    errHandler->ErrorHandling.log
    errHandler->ErrorHandling.raiseExn
  }
}

let checkAndFetchForChain = (chain, ~state, ~dispatchAction) => {
  let {fetchState, chainWorker, logger, currentBlockHeight, isFetchingBatch} =
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
      logger->Logging.childTrace("Waiting for new blocks")
      let compose = async (worker, waitForBlockGreaterThanCurrentHeight) => {
        let logger = Logging.createChildFrom(
          ~logger,
          ~params={
            "logType": "Poll for block greater than current height",
            "currentBlockHeight": currentBlockHeight,
          },
        )
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

      let compose = async (worker, fetchBlockRange, workerType) => {
        let logger = Logging.createChildFrom(
          ~logger,
          ~params={"logType": "Block Range Query", "workerType": workerType},
        )
        let logger = query->FetchState.getQueryLogger(~logger)
        let res =
          await worker->fetchBlockRange(
            ~query,
            ~logger,
            ~currentBlockHeight,
            ~setCurrentBlockHeight,
          )
        switch res {
        | Ok(res) => dispatchAction(BlockRangeResponse(chain, res))
        | Error(e) => dispatchAction(ErrorExit(e))
        }
      }

      switch chainWorker {
      | HyperSync(worker) => compose(worker, HyperSyncWorker.fetchBlockRange, "HyperSync")
      | Rpc(worker) => compose(worker, RpcWorker.fetchBlockRange, "RPC")
      }->ignore
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
          ~saveRawEvents=state.saveRawEvents,
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
      | None => dispatchAction(SetSyncedChains) //Known that there are no items available on the queue so safely call this action
      }
    }
  }
}
