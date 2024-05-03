open Belt

type chain = ChainMap.Chain.t
type rollbackState = NoRollback | RollingBack(chain) | RollbackInMemStore(IO.InMemoryStore.t)

type t = {
  chainManager: ChainManager.t,
  currentlyProcessingBatch: bool,
  rollbackState: rollbackState,
  maxBatchSize: int,
  maxPerChainQueueSize: int,
  indexerStartTime: Js.Date.t,
  //Initialized as 0, increments, when rollbacks occur to invalidate
  //responses based on the wrong stateId
  id: int,
}

let make = (~chainManager) => {
  currentlyProcessingBatch: false,
  chainManager,
  maxBatchSize: Env.maxProcessBatchSize,
  maxPerChainQueueSize: {
    let numChains = Config.config->ChainMap.size
    Env.maxEventFetchedQueueSize / numChains
  },
  indexerStartTime: Js.Date.make(),
  rollbackState: NoRollback,
  id: 0,
}

let getId = self => self.id
let incrementId = self => {...self, id: self.id + 1}
let setRollingBack = (self, chain) => {...self, rollbackState: RollingBack(chain)}
let setChainManager = (self, chainManager) => {
  ...self,
  chainManager,
}

let isRollingBack = state =>
  switch state.rollbackState {
  | RollingBack(_) => true
  | _ => false
  }

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
  | SuccessExit
  | ErrorExit(ErrorHandling.t)
  | SetRollbackState(IO.InMemoryStore.t, ChainManager.t)
  | ResetRollbackState

type queryChain = CheckAllChains | Chain(chain)
type task =
  | NextQuery(queryChain)
  | ProcessEventBatch
  | UpdateChainMetaData
  | Rollback

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
      let latestFetchedBlockNumber = cf.fetchState->FetchState.getLatestFullyFetchedBlock
      let chainMetadata: DbFunctions.ChainMetadata.chainMetadata = {
        chainId: cf.chainConfig.chain->ChainMap.Chain.toChainId,
        startBlock: cf.chainConfig.startBlock,
        blockHeight: cf.currentBlockHeight,
        //optional fields
        endBlock: cf.chainConfig.endBlock, //this is already optional
        firstEventBlockNumber: cf.firstEventBlockNumber, //this is already optional
        latestProcessedBlock: cf.latestProcessedBlock, // this is already optional
        numEventsProcessed: Some(cf.numEventsProcessed),
        isHyperSync: switch cf.chainConfig.syncSource {
        | HyperSync(_) => true
        | Rpc(_) => false
        },
        numBatchesFetched: cf.numBatchesFetched,
        latestFetchedBlockNumber,
        timestampCaughtUpToHeadOrEndblock: cf.timestampCaughtUpToHeadOrEndblock,
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

  //Update the timestampCaughtUpToHeadOrEndblock values
  let chainFetchers = chainManager.chainFetchers->ChainMap.map(cf => {
    if cf.latestProcessedBlock >= cf.chainConfig.endBlock {
      {
        ...cf,
        timestampCaughtUpToHeadOrEndblock: Js.Date.make()->Some,
      }
    } else if cf.timestampCaughtUpToHeadOrEndblock->Option.isNone && cf.isFetchingAtHead {
      //Only calculate and set timestampCaughtUpToHeadOrEndblock if chain fetcher is at the head and
      //its not already set
      //CASE1
      //All chains are caught up to head chainManager queue returns None
      //Meaning we are busy synchronizing chains at the head
      if nextQueueItemIsNone && allChainsAtHead {
        {
          ...cf,
          timestampCaughtUpToHeadOrEndblock: Js.Date.make()->Some,
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
            timestampCaughtUpToHeadOrEndblock: Js.Date.make()->Some,
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

let greaterThanOrEqualOpt: (option<int>, option<int>) => bool = (opt1, opt2) => {
  switch (opt1, opt2) {
  | (Some(num1), Some(num2)) => num1 >= num2
  | _ => false
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
        FetchState.getLatestFullyFetchedBlock(fetchState).blockNumber->Some
      } else {
        latestProcessedBlock
      }

      {
        ...cf,
        latestProcessedBlock,
        numEventsProcessed,
        hasProcessedToEndblock: latestProcessedBlock->greaterThanOrEqualOpt(
          cf.chainConfig.endBlock,
        ),
      }
    }),
  }
  {
    ...state,
    chainManager: chainManager->checkAndSetSyncedChains,
    currentlyProcessingBatch: false,
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

  let {parentHash, lastBlockScannedData} = reorgGuard

  let hasReorgOccurred =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.hasReorgOccurred(
      ~parentHash,
    )

  if !hasReorgOccurred {
    let chainFetcher =
      chainFetcher
      ->ChainFetcher.updateFetchState(
        ~latestFetchedBlockTimestamp,
        ~latestFetchedBlockNumber=heighestQueriedBlockNumber,
        ~fetchedEvents=parsedQueueItems->List.fromArray,
        ~id=fetchStateRegisterId,
      )
      ->Utils.unwrapResultExn
      ->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)

    let firstEventBlockNumber = switch parsedQueueItems[0] {
    | Some(item) if chainFetcher.firstEventBlockNumber->Option.isNone => item.blockNumber->Some
    | _ => chainFetcher.firstEventBlockNumber
    }

    let hasArbQueueEvents =
      state.chainManager.arbitraryEventPriorityQueue
      ->ChainManager.getFirstArbitraryEventsItemForChain(~chain)
      ->Option.isSome //TODO this is more expensive than it needs to be
    let queueSize = chainFetcher.fetchState->FetchState.queueSize
    let hasNoMoreEventsToProcess = !hasArbQueueEvents && queueSize == 0

    let latestProcessedBlock = if hasNoMoreEventsToProcess {
      FetchState.getLatestFullyFetchedBlock(chainFetcher.fetchState).blockNumber->Some
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
      isFetchingBatch: false,
      firstEventBlockNumber,
      latestProcessedBlock,
      isFetchingAtHead,
      numBatchesFetched: chainFetcher.numBatchesFetched + 1,
    }

    let chainManager = {
      ...state.chainManager,
      chainFetchers: state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher),
    }->ChainManager.addLastBlockScannedData(
      ~chain,
      ~lastBlockScannedData,
      ~currentHeight=currentBlockHeight,
    )

    let nextState = {
      ...state,
      chainManager,
    }

    Prometheus.setFetchedEventsUntilHeight(~blockNumber=response.heighestQueriedBlockNumber, ~chain)

    (nextState, [UpdateChainMetaData, ProcessEventBatch, NextQuery(Chain(chain))])
  } else {
    chainFetcher.logger->Logging.childWarn("Reorg detected, rolling back")
    let chainFetcher = {
      ...chainFetcher,
      isFetchingBatch: false,
    }
    let chainManager = state.chainManager->ChainManager.setChainFetcher(chainFetcher)
    (state->setChainManager(chainManager)->incrementId->setRollingBack(chain), [Rollback])
  }
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
        timestampCaughtUpToHeadOrEndblock: None,
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
      }
    })

    // This ONLY updates the metrics - no logic is performed.
    nextState.chainManager.chainFetchers
    ->ChainMap.entries
    ->Array.forEach(((chain, chainFetcher)) => {
      let highestFetchedBlockOnChain = FetchState.getLatestFullyFetchedBlock(
        chainFetcher.fetchState,
      ).blockNumber

      Prometheus.setFetchedEventsUntilHeight(~blockNumber=highestFetchedBlockOnChain, ~chain)
    })
    let nextState = updateLatestProcessedBlocks(~state=nextState, ~latestProcessedBlocks=val)
    (nextState, nextTasks)

  | EventBatchProcessed({val, dynamicContractRegistrations: None}) => (
      updateLatestProcessedBlocks(~state, ~latestProcessedBlocks=val),
      [UpdateChainMetaData, ProcessEventBatch],
    )
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
  | SetRollbackState(inMemoryStore, chainManager) => (
      {...state, rollbackState: RollbackInMemStore(inMemoryStore), chainManager},
      [NextQuery(CheckAllChains), ProcessEventBatch],
    )
  | ResetRollbackState => ({...state, rollbackState: NoRollback}, [])
  | SuccessExit =>
    NodeJsLocal.process->NodeJsLocal.exitWithCode(Success)
    (state, [])
  | ErrorExit(errHandler) =>
    errHandler->ErrorHandling.log
    NodeJsLocal.process->NodeJsLocal.exitWithCode(Failure)
    (state, [])
  }
}

let invalidatedActionReducer = (state: t, action: action) =>
  switch action {
  | EventBatchProcessed(_) => ({...state, currentlyProcessingBatch: false}, [Rollback])
  | _ => (state, [])
  }

let waitForNewBlock = (
  ~logger,
  ~chainWorker: SourceWorker.sourceWorker,
  ~currentBlockHeight,
  ~setCurrentBlockHeight,
) => {
  logger->Logging.childTrace("Waiting for new blocks")
  let compose = async (worker, waitForBlockGreaterThanCurrentHeight) => {
    let logger = Logging.createChildFrom(
      ~logger,
      ~params={
        "logType": "Poll for block greater than current height",
        "currentBlockHeight": currentBlockHeight,
      },
    )
    let newHeight = await worker->waitForBlockGreaterThanCurrentHeight(~currentBlockHeight, ~logger)
    setCurrentBlockHeight(newHeight)
  }
  switch chainWorker {
  | Config.HyperSync(w) => compose(w, HyperSyncWorker.waitForBlockGreaterThanCurrentHeight)
  | Rpc(w) => compose(w, RpcWorker.waitForBlockGreaterThanCurrentHeight)
  }
}

let executeNextQuery = (
  ~logger,
  ~chainWorker,
  ~currentBlockHeight,
  ~setCurrentBlockHeight,
  ~chain,
  ~query,
  ~dispatchAction,
) => {
  let compose = async (worker, fetchBlockRange, workerType) => {
    let logger = Logging.createChildFrom(
      ~logger,
      ~params={"logType": "Block Range Query", "workerType": workerType},
    )
    let logger = query->FetchState.getQueryLogger(~logger)
    let res =
      await worker->fetchBlockRange(~query, ~logger, ~currentBlockHeight, ~setCurrentBlockHeight)
    switch res {
    | Ok(res) => dispatchAction(BlockRangeResponse(chain, res))
    | Error(e) => dispatchAction(ErrorExit(e))
    }
  }

  switch chainWorker {
  | Config.HyperSync(worker) => compose(worker, HyperSyncWorker.fetchBlockRange, "HyperSync")
  | Rpc(worker) => compose(worker, RpcWorker.fetchBlockRange, "RPC")
  }
}

let checkAndFetchForChain = async (
  //Used for dependency injection for tests
  ~waitForNewBlock,
  ~executeNextQuery,
  //required args
  ~state,
  ~dispatchAction,
  chain,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let {fetchState, chainWorker, logger, currentBlockHeight, isFetchingBatch} = chainFetcher

  if (
    !isFetchingBatch &&
    fetchState->FetchState.isReadyForNextQuery(~maxQueueSize=state.maxPerChainQueueSize) &&
    !isRollingBack(state)
  ) {
    let (nextQuery, nextStateIfChangeRequired) =
      chainFetcher
      ->ChainFetcher.getNextQuery
      ->Utils.unwrapResultExn

    switch nextStateIfChangeRequired {
    | Some(nextFetchState) => dispatchAction(SetFetchState(chain, nextFetchState))
    | None => ()
    }

    let setCurrentBlockHeight = currentBlockHeight =>
      dispatchAction(SetFetchStateCurrentBlockHeight(chain, currentBlockHeight))

    switch nextQuery {
    | WaitForNewBlock =>
      await waitForNewBlock(~logger, ~chainWorker, ~currentBlockHeight, ~setCurrentBlockHeight)
    | NextQuery(query) =>
      dispatchAction(SetCurrentlyFetchingBatch(chain, true))
      await executeNextQuery(
        ~logger,
        ~chainWorker,
        ~currentBlockHeight,
        ~setCurrentBlockHeight,
        ~chain,
        ~query,
        ~dispatchAction,
      )
    | Done => ()
    }
  }
}

let injectedTaskReducer = async (
  //Used for dependency injection for tests
  ~waitForNewBlock,
  ~executeNextQuery,
  ~rollbackLastBlockHashesToReorgLocation,
  //required args
  state: t,
  task: task,
  ~dispatchAction,
) => {
  switch task {
  | UpdateChainMetaData => await updateChainMetadataTable(state.chainManager)
  | NextQuery(chainCheck) =>
    let fetchForChain = checkAndFetchForChain(
      ~waitForNewBlock,
      ~executeNextQuery,
      ~state,
      ~dispatchAction,
    )

    switch chainCheck {
    | Chain(chain) => await chain->fetchForChain
    | CheckAllChains =>
      //Mapping from the states chainManager so we can construct tests that don't use
      //all chains
      let _ =
        await state.chainManager.chainFetchers
        ->ChainMap.keys
        ->Array.map(fetchForChain(_))
        ->Promise.all
    }
  | ProcessEventBatch =>
    if !state.currentlyProcessingBatch && !isRollingBack(state) {
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

        //In the case of a rollback, use the provided in memory store
        //With rolled back values
        let rollbackInMemStore = switch state.rollbackState {
        | RollbackInMemStore(inMemoryStore) => Some(inMemoryStore)
        | NoRollback | RollingBack(_) /* This is an impossible case due to the surrounding if statement check */ => None
        }

        let inMemoryStore = rollbackInMemStore->Option.getWithDefault(IO.InMemoryStore.make())
        switch await EventProcessing.processEventBatch(
          ~eventBatch=batch,
          ~inMemoryStore,
          ~checkContractIsRegistered,
          ~latestProcessedBlocks,
        ) {
        | exception exn =>
          //All casese should be handled/caught before this with better user messaging.
          //This is just a safety in case something unexpected happens
          let errHandler =
            exn->ErrorHandling.make(~msg="A top level unexpected error occurred during processing")
          dispatchAction(ErrorExit(errHandler))
        | res =>
          if rollbackInMemStore->Option.isSome {
            //if the batch was executed with a rollback inMemoryStore
            //reset the rollback state once the batch has been processed
            dispatchAction(ResetRollbackState)
          }
          switch res {
          | Ok(loadRes) => dispatchAction(EventBatchProcessed(loadRes))
          | Error(errHandler) => dispatchAction(ErrorExit(errHandler))
          }
        }
      | None => {
          dispatchAction(SetSyncedChains) //Known that there are no items available on the queue so safely call this action
          if (
            EventProcessing.EventsProcessed.allChainsEventsProcessedToEndblock(
              state.chainManager.chainFetchers,
            )
          ) {
            dispatchAction(SuccessExit)
          }
        }
      }
    }
  | Rollback =>
    //If it isn't processing a batch currently continue with rollback otherwise wait for current batch to finish processing
    switch state {
    | {currentlyProcessingBatch: false, rollbackState: RollingBack(rollbackChain)} =>
      Logging.warn("Executing rollback")
      let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(rollbackChain)
      let rollbackChainId = rollbackChain->ChainMap.Chain.toChainId
      //Get rollback block and timestamp
      let reorgChainRolledBackLastBlockData =
        await chainFetcher->rollbackLastBlockHashesToReorgLocation

      let {blockNumber: lastKnownValidBlockNumber, blockTimestamp: lastKnownValidBlockTimestamp} =
        reorgChainRolledBackLastBlockData->ChainFetcher.getLastScannedBlockData

      let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
        let rolledBackLastBlockData = if chain == rollbackChain {
          //For the chain fetcher of the chain where a  reorg occured, use the the
          //rolledBackLastBlockData already computed
          reorgChainRolledBackLastBlockData
        } else {
          //For all other chains, rollback to where a blockTimestamp is less than or equal to the block timestamp
          //where the reorg chain is rolling back to
          cf.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.rollBackToBlockTimestampLte(
            ~blockTimestamp=lastKnownValidBlockTimestamp,
          )
        }

        //Roll back chain fetcher with the given rolledBackLastBlockData
        cf
        ->ChainFetcher.rollbackToLastBlockHashes(~rolledBackLastBlockData)
        ->ChainFetcher.addEventFilter(
          ~filter=eventBatchQueueItem => {
            let {timestamp, chain, blockNumber} = eventBatchQueueItem
            //Filter out events that occur passed the block where the query starts but
            //are lower than the timestamp where we rolled back to
            (timestamp, chain->ChainMap.Chain.toChainId, blockNumber) >
            (lastKnownValidBlockTimestamp, rollbackChainId, lastKnownValidBlockNumber)
          },
          ~isValid=(~fetchState, ~chain) => {
            //Remove the event filter once the fetchState has fetched passed the
            //timestamp of the valid rollback block's timestamp
            let {blockTimestamp, blockNumber} = FetchState.getLatestFullyFetchedBlock(fetchState)
            (blockTimestamp, chain->ChainMap.Chain.toChainId, blockNumber) <=
            (lastKnownValidBlockTimestamp, rollbackChainId, lastKnownValidBlockNumber)
          },
        )
      })

      let chainManager = {
        ...state.chainManager,
        chainFetchers,
      }

      //Construct a rolledback in Memory store
      let inMemoryStore = await IO.RollBack.rollBack(
        ~chainId=rollbackChain->ChainMap.Chain.toChainId,
        ~blockTimestamp=lastKnownValidBlockTimestamp,
        ~blockNumber=lastKnownValidBlockNumber,
        ~logIndex=0,
      )

      dispatchAction(SetRollbackState(inMemoryStore, chainManager))

    | _ => Logging.warn("Waiting for batch to finish processing before executing rollback") //wait for batch to finish processing
    }
  }
}
let taskReducer = injectedTaskReducer(
  ~waitForNewBlock,
  ~executeNextQuery,
  ~rollbackLastBlockHashesToReorgLocation=ChainFetcher.rollbackLastBlockHashesToReorgLocation(_),
)
