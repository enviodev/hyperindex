open Belt

type chain = ChainMap.Chain.t
type rollbackState = NoRollback | RollingBack(chain) | RollbackInMemStore(InMemoryStore.t)

type t = {
  config: Config.t,
  chainManager: ChainManager.t,
  currentlyProcessingBatch: bool,
  rollbackState: rollbackState,
  maxBatchSize: int,
  maxPerChainQueueSize: int,
  indexerStartTime: Js.Date.t,
  asyncTaskQueue: AsyncTaskQueue.t,
  //Initialized as 0, increments, when rollbacks occur to invalidate
  //responses based on the wrong stateId
  id: int,
}

let make = (~config, ~chainManager) => {
  config,
  currentlyProcessingBatch: false,
  chainManager,
  maxBatchSize: Env.maxProcessBatchSize,
  maxPerChainQueueSize: {
    let numChains = config.chainMap->ChainMap.size
    Env.maxEventFetchedQueueSize / numChains
  },
  indexerStartTime: Js.Date.make(),
  rollbackState: NoRollback,
  asyncTaskQueue: AsyncTaskQueue.make(),
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

type shouldExit = ExitWithSuccess | NoExit
type action =
  | BlockRangeResponse(chain, ChainWorker.blockRangeFetchResponse)
  | SetFetchStateCurrentBlockHeight(chain, int)
  | EventBatchProcessed(EventProcessing.batchProcessed)
  | SetCurrentlyProcessing(bool)
  | SetCurrentlyFetchingBatch(chain, bool)
  | SetFetchState(chain, PartitionedFetchState.t)
  | UpdateQueues(ChainMap.t<PartitionedFetchState.t>, arbitraryEventQueue)
  | SetSyncedChains
  | SuccessExit
  | ErrorExit(ErrorHandling.t)
  | SetRollbackState(InMemoryStore.t, ChainManager.t)
  | ResetRollbackState

type queryChain = CheckAllChains | Chain(chain)
type task =
  | NextQuery(queryChain)
  | UpdateEndOfBlockRangeScannedData({
      chain: chain,
      blockNumberThreshold: int,
      blockTimestampThreshold: int,
      nextEndOfBlockRangeScannedData: DbFunctions.EndOfBlockRangeScannedData.endOfBlockRangeScannedData,
    })
  | ProcessEventBatch
  | UpdateChainMetaDataAndCheckForExit(shouldExit)
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

let updateChainMetadataTable = async (cm: ChainManager.t, ~asyncTaskQueue: AsyncTaskQueue.t) => {
  let chainMetadataArray: array<DbFunctions.ChainMetadata.chainMetadata> =
    cm.chainFetchers
    ->ChainMap.values
    ->Belt.Array.map(cf => {
      let latestFetchedBlock = cf.fetchState->PartitionedFetchState.getLatestFullyFetchedBlock
      let chainMetadata: DbFunctions.ChainMetadata.chainMetadata = {
        chainId: cf.chainConfig.chain->ChainMap.Chain.toChainId,
        startBlock: cf.chainConfig.startBlock,
        blockHeight: cf.currentBlockHeight,
        //optional fields
        endBlock: cf.chainConfig.endBlock, //this is already optional
        firstEventBlockNumber: cf.firstEventBlockNumber, //this is already optional
        latestProcessedBlock: cf.latestProcessedBlock, // this is already optional
        numEventsProcessed: Some(cf.numEventsProcessed),
        poweredByHyperSync: switch cf.chainConfig.syncSource {
        | HyperSync(_)
        | HyperFuel(_) => true
        | Rpc(_) => false
        },
        numBatchesFetched: cf.numBatchesFetched,
        latestFetchedBlockNumber: latestFetchedBlock.blockNumber,
        timestampCaughtUpToHeadOrEndblock: cf.timestampCaughtUpToHeadOrEndblock->Js.Nullable.fromOption,
      }
      chainMetadata
    })
  //Don't await this set, it can happen in its own time
  await asyncTaskQueue->AsyncTaskQueue.add(() =>
    DbFunctions.ChainMetadata.batchSetChainMetadataRow(~chainMetadataArray)
  )
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
    ->Array.reduce(true, (accum, cf) => cf->ChainFetcher.isFetchingAtHead && accum)

  //Update the timestampCaughtUpToHeadOrEndblock values
  let chainFetchers = chainManager.chainFetchers->ChainMap.map(cf => {
    /* strategy for TUI synced status:
     * Firstly -> only update synced status after batch is processed (not on batch creation). But also set when a batch tries to be created and there is no batch
     *
     * Secondly -> reset timestampCaughtUpToHead and isFetching at head when dynamic contracts get registered to a chain if they are not within 0.001 percent of the current block height
     *
     * New conditions for valid synced:
     *
     * CASE 1 (chains are being synchronised at the head)
     *
     * All chain fetchers are fetching at the head AND
     * No events that can be processed on the queue (even if events still exist on the individual queues)
     * CASE 2 (chain finishes earlier than any other chain)
     *
     * CASE 3 endblock has been reached and latest processed block is greater than or equal to endblock (both fields must be Some)
     *
     * The given chain fetcher is fetching at the head or latest processed block >= endblock
     * The given chain has processed all events on the queue
     * see https://github.com/Float-Capital/indexer/pull/1388 */
    if cf->ChainFetcher.hasProcessedToEndblock {
      // in the case this is already set, don't reset and instead propagate the existing value
      let timestampCaughtUpToHeadOrEndblock =
        cf.timestampCaughtUpToHeadOrEndblock->Option.isSome
          ? cf.timestampCaughtUpToHeadOrEndblock
          : Js.Date.make()->Some
      {
        ...cf,
        timestampCaughtUpToHeadOrEndblock,
      }
    } else if (
      cf.timestampCaughtUpToHeadOrEndblock->Option.isNone && cf->ChainFetcher.isFetchingAtHead
    ) {
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
        let queueSize = cf.fetchState->PartitionedFetchState.queueSize
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
      let queueSize = fetchState->PartitionedFetchState.queueSize

      let hasNoMoreEventsToProcess = !hasArbQueueEvents && queueSize == 0

      let latestProcessedBlock = if hasNoMoreEventsToProcess {
        PartitionedFetchState.getLatestFullyFetchedBlock(fetchState).blockNumber->Some
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
    currentlyProcessingBatch: false,
  }
}

let handleBlockRangeResponse = (state, ~chain, ~response: ChainWorker.blockRangeFetchResponse) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let {
    parsedQueueItems,
    heighestQueriedBlockNumber,
    stats,
    currentBlockHeight,
    reorgGuard,
    fromBlockQueried,
    fetchStateRegisterId,
    partitionId,
    latestFetchedBlockTimestamp,
  } = response

  chainFetcher.logger->Logging.childTrace({
    "message": "Finished page range",
    "fromBlock": fromBlockQueried,
    "toBlock": heighestQueriedBlockNumber,
    "number of logs": parsedQueueItems->Array.length,
    "stats": stats,
  })

  let {firstBlockParentNumberAndHash, lastBlockScannedData} = reorgGuard

  let hasReorgOccurred =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.hasReorgOccurred(
      ~firstBlockParentNumberAndHash,
    )

  if !hasReorgOccurred || !(state.config->Config.shouldRollbackOnReorg) {
    if hasReorgOccurred {
      chainFetcher.logger->Logging.childWarn(
        "Reorg detected, not rolling back due to configuration",
      )
      Prometheus.incrementReorgsDetected(~chain)
    }

    let chainFetcher =
      chainFetcher
      ->ChainFetcher.updateFetchState(
        ~currentBlockHeight,
        ~latestFetchedBlockTimestamp,
        ~latestFetchedBlockNumber=heighestQueriedBlockNumber,
        ~fetchedEvents=parsedQueueItems->List.fromArray,
        ~id={fetchStateId: fetchStateRegisterId, partitionId},
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
    let queueSize = chainFetcher.fetchState->PartitionedFetchState.queueSize
    let hasNoMoreEventsToProcess = !hasArbQueueEvents && queueSize == 0

    let latestProcessedBlock = if hasNoMoreEventsToProcess {
      PartitionedFetchState.getLatestFullyFetchedBlock(chainFetcher.fetchState).blockNumber->Some
    } else {
      chainFetcher.latestProcessedBlock
    }

    if currentBlockHeight <= heighestQueriedBlockNumber {
      if !ChainFetcher.isFetchingAtHead(chainFetcher) {
        chainFetcher.logger->Logging.childInfo(
          "All events have been fetched, they should finish processing the handlers soon.",
        )
      }
    }

    let updatedChainFetcher = {
      ...chainFetcher,
      isFetchingBatch: false,
      firstEventBlockNumber,
      latestProcessedBlock,
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

    let updateEndOfBlockRangeScannedDataArr =
      //Only update endOfBlockRangeScannedData if rollbacks are enabled
      state.config->Config.shouldRollbackOnReorg
        ? [
            UpdateEndOfBlockRangeScannedData({
              chain,
              blockNumberThreshold: lastBlockScannedData.blockNumber -
              chainFetcher.chainConfig.confirmedBlockThreshold,
              blockTimestampThreshold: chainManager
              ->ChainManager.getEarliestMultiChainTimestampInThreshold
              ->Option.getWithDefault(0),
              nextEndOfBlockRangeScannedData: {
                chainId: chain->ChainMap.Chain.toChainId,
                blockNumber: lastBlockScannedData.blockNumber,
                blockTimestamp: lastBlockScannedData.blockTimestamp,
                blockHash: lastBlockScannedData.blockHash,
              },
            }),
          ]
        : []

    let nextState = {
      ...state,
      chainManager,
    }

    Prometheus.setFetchedEventsUntilHeight(~blockNumber=response.heighestQueriedBlockNumber, ~chain)

    (
      nextState,
      Array.concat(
        updateEndOfBlockRangeScannedDataArr,
        [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
      ),
    )
  } else {
    chainFetcher.logger->Logging.childWarn("Reorg detected, rolling back")
    Prometheus.incrementReorgsDetected(~chain)
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
      latestProcessedBlocks,
      dynamicContractRegistrations: Some({registrationsReversed, unprocessedBatchReversed}),
    }) =>
    let updatedArbQueue =
      unprocessedBatchReversed->List.reverse->FetchState.mergeSortedList(~cmp=(a, b) => {
        a->EventUtils.getEventComparatorFromQueueItem <
          b->EventUtils.getEventComparatorFromQueueItem
      }, state.chainManager.arbitraryEventPriorityQueue)

    let nextTasks = [
      UpdateChainMetaDataAndCheckForExit(NoExit),
      ProcessEventBatch,
      NextQuery(CheckAllChains),
    ]

    let nextState = registrationsReversed->List.reduce(state, (state, registration) => {
      let {
        registeringEventBlockNumber,
        registeringEventLogIndex,
        registeringEventChain,
        dynamicContracts,
      } = registration

      let currentChainFetcher =
        state.chainManager.chainFetchers->ChainMap.get(registeringEventChain)
      /* strategy for TUI synced status:
       * Firstly -> only update synced status after batch is processed (not on batch creation). But also set when a batch tries to be created and there is no batch
       *
       * Secondly -> reset timestampCaughtUpToHead and isFetching at head when dynamic contracts get registered to a chain if they are not within 0.001 percent of the current block height
       *
       * New conditions for valid synced:
       *
       * CASE 1 (chains are being synchronised at the head)
       *
       * All chain fetchers are fetching at the head AND
       * No events that can be processed on the queue (even if events still exist on the individual queues)
       * CASE 2 (chain finishes earlier than any other chain)
       *
       * CASE 3 endblock has been reached and latest processed block is greater than or equal to endblock (both fields must be Some)
       *
       * The given chain fetcher is fetching at the head or latest processed block >= endblock
       * The given chain has processed all events on the queue
       * see https://github.com/Float-Capital/indexer/pull/1388 */

      /* Dynamic contracts pose a unique case when calculated whether a chain is synced or not.
       * Specifically, in the initial syncing state from SearchingForEvents -> Synced, where although a chain has technically processed up to all blocks
       * for a contract that emits events with dynamic contracts, it is possible that those dynamic contracts will need to be indexed from blocks way before
       * the current block height. This is a toleration check where if there are dynamic contracts within a batch, check how far are they from the currentblock height.
       * If it is less than 1 thousandth of a percent, then we deem that contract to be within the synced range, and therefore do not reset the synced status of the chain */
      let areDynamicContractsWithinSyncRange = dynamicContracts->Array.reduce(true, (
        acc,
        contract,
      ) => {
        let {blockNumber, _} = contract.eventId->EventUtils.unpackEventIndex
        let isContractWithinSyncedRanged =
          (currentChainFetcher.currentBlockHeight->Int.toFloat -. blockNumber->Int.toFloat) /.
            currentChainFetcher.currentBlockHeight->Int.toFloat <= 0.001
        acc && isContractWithinSyncedRanged
      })

      let (isFetchingAtHead, timestampCaughtUpToHeadOrEndblock) = areDynamicContractsWithinSyncRange
        ? (
            currentChainFetcher->ChainFetcher.isFetchingAtHead,
            currentChainFetcher.timestampCaughtUpToHeadOrEndblock,
          )
        : (false, None)

      let updatedFetchState =
        currentChainFetcher.fetchState->PartitionedFetchState.registerDynamicContracts(
          ~registeringEventBlockNumber,
          ~registeringEventLogIndex,
          ~dynamicContractRegistrations=dynamicContracts,
          ~isFetchingAtHead,
        )

      let updatedChainFetcher = {
        ...currentChainFetcher,
        fetchState: updatedFetchState,
        timestampCaughtUpToHeadOrEndblock,
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
      let highestFetchedBlockOnChain = PartitionedFetchState.getLatestFullyFetchedBlock(
        chainFetcher.fetchState,
      ).blockNumber

      Prometheus.setFetchedEventsUntilHeight(~blockNumber=highestFetchedBlockOnChain, ~chain)
    })
    let nextState = updateLatestProcessedBlocks(~state=nextState, ~latestProcessedBlocks)
    (nextState, nextTasks)

  | EventBatchProcessed({latestProcessedBlocks, dynamicContractRegistrations: None}) => (
      updateLatestProcessedBlocks(~state, ~latestProcessedBlocks),
      [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch],
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
  | SetSyncedChains => {
      let shouldExit = EventProcessing.EventsProcessed.allChainsEventsProcessedToEndblock(
        state.chainManager.chainFetchers,
      )
        ? {
            Logging.info("All chains are caught up to the endblock.")
            ExitWithSuccess
          }
        : NoExit
      (
        {
          ...state,
          chainManager: state.chainManager->checkAndSetSyncedChains(~nextQueueItemIsKnownNone=true),
        },
        [UpdateChainMetaDataAndCheckForExit(shouldExit)],
      )
    }
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
  | SuccessExit => {
      Logging.info("exiting with success")
      NodeJsLocal.process->NodeJsLocal.exitWithCode(Success)
      (state, [])
    }
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

let waitForNewBlock = async (
  ~logger,
  ~chainWorker,
  ~currentBlockHeight,
  ~setCurrentBlockHeight,
) => {
  let module(ChainWorker: ChainWorker.S) = chainWorker

  logger->Logging.childTrace("Waiting for new blocks")
  let logger = Logging.createChildFrom(
    ~logger,
    ~params={
      "logType": "Poll for block greater than current height",
      "currentBlockHeight": currentBlockHeight,
    },
  )
  let newHeight = await ChainWorker.waitForBlockGreaterThanCurrentHeight(
    ~currentBlockHeight,
    ~logger,
  )
  setCurrentBlockHeight(newHeight)
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
  let module(ChainWorker: ChainWorker.S) = chainWorker

  let logger = Logging.createChildFrom(
    ~logger,
    ~params={"logType": "Block Range Query", "workerType": ChainWorker.name},
  )
  let logger = query->FetchState.getQueryLogger(~logger)
  ChainWorker.fetchBlockRange(
    ~query,
    ~logger,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
  )->Promise.thenResolve(res =>
    switch res {
    | Ok(res) => dispatchAction(BlockRangeResponse(chain, res))
    | Error(e) => dispatchAction(ErrorExit(e))
    }
  )
}

let checkAndFetchForChain = (
  //Used for dependency injection for tests
  ~waitForNewBlock,
  ~executeNextQuery,
  //required args
  ~state,
  ~dispatchAction,
) =>
  async chain => {
    let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
    let {fetchState, chainWorker, logger, currentBlockHeight, isFetchingBatch} = chainFetcher

    if (
      !isFetchingBatch &&
      fetchState->PartitionedFetchState.isReadyForNextQuery(
        ~maxQueueSize=state.maxPerChainQueueSize,
      ) &&
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

let injectedTaskReducer = (
  //Used for dependency injection for tests
  ~waitForNewBlock,
  ~executeNextQuery,
  ~rollbackLastBlockHashesToReorgLocation,
  ~registeredEvents,
) =>
  async (
    //required args
    state: t,
    task: task,
    ~dispatchAction,
  ) => {
    switch task {
    | UpdateEndOfBlockRangeScannedData({
        chain,
        blockNumberThreshold,
        blockTimestampThreshold,
        nextEndOfBlockRangeScannedData,
      }) =>
      await DbFunctions.sql->Postgres.beginSql(sql => {
        [
          DbFunctions.EndOfBlockRangeScannedData.setEndOfBlockRangeScannedData(
            sql,
            nextEndOfBlockRangeScannedData,
          ),
          DbFunctions.EndOfBlockRangeScannedData.deleteStaleEndOfBlockRangeScannedDataForChain(
            sql,
            ~chainId=chain->ChainMap.Chain.toChainId,
            ~blockTimestampThreshold,
            ~blockNumberThreshold,
          ),
        ]->Array.concat(
          //only prune history if we are not saving full history
          state.config->Config.shouldPruneHistory
            ? [
                DbFunctions.EntityHistory.deleteAllEntityHistoryOnChainBeforeThreshold(
                  sql,
                  ~chainId=chain->ChainMap.Chain.toChainId,
                  ~blockNumberThreshold,
                  ~blockTimestampThreshold,
                ),
              ]
            : [],
        )
      })
    | UpdateChainMetaDataAndCheckForExit(shouldExit) =>
      let {chainManager, asyncTaskQueue} = state
      switch shouldExit {
      | ExitWithSuccess =>
        updateChainMetadataTable(chainManager, ~asyncTaskQueue)
        ->Promise.thenResolve(_ => dispatchAction(SuccessExit))
        ->ignore
      | NoExit => updateChainMetadataTable(chainManager, ~asyncTaskQueue)->ignore
      }
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
          let checkContractIsRegistered = (
            ~chain,
            ~contractAddress,
            ~contractName: Enums.ContractType.t,
          ) => {
            let fetchState = fetchStatesMap->ChainMap.get(chain)
            fetchState->PartitionedFetchState.checkContainsRegisteredContractAddress(
              ~contractAddress,
              ~contractName=(contractName :> string),
            )
          }

          let latestProcessedBlocks = EventProcessing.EventsProcessed.makeFromChainManager(
            state.chainManager,
          )

          //In the case of a rollback, use the provided in memory store
          //With rolled back values
          let rollbackInMemStore = switch state.rollbackState {
          | RollbackInMemStore(inMemoryStore) => Some(inMemoryStore)
          | NoRollback
          | RollingBack(
            _,
          ) /* This is an impossible case due to the surrounding if statement check */ =>
            None
          }

          let inMemoryStore = rollbackInMemStore->Option.getWithDefault(InMemoryStore.make())
          switch await EventProcessing.processEventBatch(
            ~eventBatch=batch,
            ~inMemoryStore,
            ~checkContractIsRegistered,
            ~latestProcessedBlocks,
            ~registeredEvents,
            ~config=state.config,
          ) {
          | exception exn =>
            //All casese should be handled/caught before this with better user messaging.
            //This is just a safety in case something unexpected happens
            let errHandler =
              exn->ErrorHandling.make(
                ~msg="A top level unexpected error occurred during processing",
              )
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
        | None => dispatchAction(SetSyncedChains) //Known that there are no items available on the queue so safely call this action
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
  ~registeredEvents=RegisteredEvents.global,
)
