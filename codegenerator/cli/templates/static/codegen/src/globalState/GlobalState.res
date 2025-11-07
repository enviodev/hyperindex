open Belt

type chain = ChainMap.Chain.t
type rollbackState =
  | NoRollback
  | ReorgDetected({chain: chain, blockNumber: int})
  | FindingReorgDepth
  | FoundReorgDepth({chain: chain, rollbackTargetBlockNumber: int})
  | RollbackReady({diffInMemoryStore: InMemoryStore.t, eventsProcessedDiffByChain: dict<int>})

module WriteThrottlers = {
  type t = {
    chainMetaData: Throttler.t,
    pruneStaleEntityHistory: Throttler.t,
  }
  let make = (): t => {
    let chainMetaData = {
      let intervalMillis = Env.ThrottleWrites.chainMetadataIntervalMillis
      let logger = Logging.createChild(
        ~params={
          "context": "Throttler for chain metadata writes",
          "intervalMillis": intervalMillis,
        },
      )
      Throttler.make(~intervalMillis, ~logger)
    }

    let pruneStaleEntityHistory = {
      let intervalMillis = Env.ThrottleWrites.pruneStaleDataIntervalMillis
      let logger = Logging.createChild(
        ~params={
          "context": "Throttler for pruning stale entity history data",
          "intervalMillis": intervalMillis,
        },
      )
      Throttler.make(~intervalMillis, ~logger)
    }
    {chainMetaData, pruneStaleEntityHistory}
  }
}

type t = {
  indexer: Indexer.t,
  chainManager: ChainManager.t,
  processedBatches: int,
  currentlyProcessingBatch: bool,
  rollbackState: rollbackState,
  indexerStartTime: Js.Date.t,
  writeThrottlers: WriteThrottlers.t,
  loadManager: LoadManager.t,
  keepProcessAlive: bool,
  //Initialized as 0, increments, when rollbacks occur to invalidate
  //responses based on the wrong stateId
  id: int,
}

let make = (
  ~indexer: Indexer.t,
  ~chainManager: ChainManager.t,
  ~isDevelopmentMode=false,
  ~shouldUseTui=false,
) => {
  {
    indexer,
    currentlyProcessingBatch: false,
    processedBatches: 0,
    chainManager,
    indexerStartTime: Js.Date.make(),
    rollbackState: NoRollback,
    writeThrottlers: WriteThrottlers.make(),
    loadManager: LoadManager.make(),
    keepProcessAlive: isDevelopmentMode || shouldUseTui,
    id: 0,
  }
}

let getId = self => self.id
let incrementId = self => {...self, id: self.id + 1}
let setChainManager = (self, chainManager) => {
  ...self,
  chainManager,
}

let isPreparingRollback = state =>
  switch state.rollbackState {
  | NoRollback
  | // We already updated fetch states here
  // so we treat it as not rolling back
  RollbackReady(_) => false
  | FindingReorgDepth
  | ReorgDetected(_)
  | FoundReorgDepth(_) => true
  }

type partitionQueryResponse = {
  chain: chain,
  response: Source.blockRangeFetchResponse,
  query: FetchState.query,
}

type shouldExit = ExitWithSuccess | NoExit

// Need to dispatch an action for every async operation
// to get access to the latest state.
type action =
  // After a response is received, we validate it with the new state
  // if there's no reorg to continue processing the response.
  | ValidatePartitionQueryResponse(partitionQueryResponse)
  // This should be a separate action from ValidatePartitionQueryResponse
  // because when processing the response, there might be an async contract registration.
  // So after it's finished we dispatch the  submit action to get the latest fetch state.
  | SubmitPartitionQueryResponse({
      newItems: array<Internal.item>,
      newItemsWithDcs: array<Internal.item>,
      currentBlockHeight: int,
      latestFetchedBlock: FetchState.blockNumberAndTimestamp,
      query: FetchState.query,
      chain: chain,
    })
  | FinishWaitingForNewBlock({chain: chain, currentBlockHeight: int})
  | EventBatchProcessed({batch: Batch.t})
  | StartProcessingBatch
  | StartFindingReorgDepth
  | FindReorgDepth({chain: chain, rollbackTargetBlockNumber: int})
  | EnterReorgThreshold
  | UpdateQueues({
      progressedChainsById: dict<Batch.chainAfterBatch>,
      // Needed to prevent overwriting the blockLag
      // set by EnterReorgThreshold
      shouldEnterReorgThreshold: bool,
    })
  | SuccessExit
  | ErrorExit(ErrorHandling.t)
  | SetRollbackState({
      diffInMemoryStore: InMemoryStore.t,
      rollbackedChainManager: ChainManager.t,
      eventsProcessedDiffByChain: dict<int>,
    })

type queryChain = CheckAllChains | Chain(chain)
type task =
  | NextQuery(queryChain)
  | ProcessPartitionQueryResponse(partitionQueryResponse)
  | ProcessEventBatch
  | UpdateChainMetaDataAndCheckForExit(shouldExit)
  | Rollback
  | PruneStaleEntityHistory

let updateChainFetcherCurrentBlockHeight = (chainFetcher: ChainFetcher.t, ~currentBlockHeight) => {
  if currentBlockHeight > chainFetcher.currentBlockHeight {
    Prometheus.setSourceChainHeight(
      ~blockNumber=currentBlockHeight,
      ~chainId=chainFetcher.chainConfig.id,
    )

    {
      ...chainFetcher,
      currentBlockHeight,
    }
  } else {
    chainFetcher
  }
}

let updateChainMetadataTable = (
  cm: ChainManager.t,
  ~persistence: Persistence.t,
  ~throttler: Throttler.t,
) => {
  let chainsData: dict<InternalTable.Chains.metaFields> = Js.Dict.empty()

  cm.chainFetchers
  ->ChainMap.values
  ->Belt.Array.forEach(cf => {
    chainsData->Js.Dict.set(
      cf.chainConfig.id->Belt.Int.toString,
      {
        blockHeight: cf.currentBlockHeight,
        firstEventBlockNumber: cf.firstEventBlockNumber->Js.Null.fromOption,
        isHyperSync: (cf.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
        latestFetchedBlockNumber: cf.fetchState->FetchState.bufferBlockNumber,
        timestampCaughtUpToHeadOrEndblock: cf.timestampCaughtUpToHeadOrEndblock->Js.Null.fromOption,
        numBatchesFetched: cf.numBatchesFetched,
      },
    )
  })

  //Don't await this set, it can happen in its own time
  throttler->Throttler.schedule(() =>
    persistence.sql
    ->InternalTable.Chains.setMeta(~pgSchema=Db.publicSchema, ~chainsData)
    ->Promise.ignoreValue
  )
}

/**
Takes in a chain manager and sets all chains timestamp caught up to head
when valid state lines up and returns an updated chain manager
*/
let updateProgressedChains = (chainManager: ChainManager.t, ~batch: Batch.t) => {
  Prometheus.ProgressBatchCount.increment()

  let nextQueueItemIsNone = chainManager->ChainManager.nextItemIsNone

  let allChainsAtHead = chainManager->ChainManager.isProgressAtHead
  //Update the timestampCaughtUpToHeadOrEndblock values
  let chainFetchers = chainManager.chainFetchers->ChainMap.map(cf => {
    let chain = ChainMap.Chain.makeUnsafe(~chainId=cf.chainConfig.id)

    let maybeChainAfterBatch =
      batch.progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
        chain->ChainMap.Chain.toChainId,
      )

    let cf = switch maybeChainAfterBatch {
    | Some(chainAfterBatch) => {
        if cf.committedProgressBlockNumber !== chainAfterBatch.progressBlockNumber {
          Prometheus.ProgressBlockNumber.set(
            ~blockNumber=chainAfterBatch.progressBlockNumber,
            ~chainId=chain->ChainMap.Chain.toChainId,
          )
        }
        if cf.numEventsProcessed !== chainAfterBatch.totalEventsProcessed {
          Prometheus.ProgressEventsCount.set(
            ~processedCount=chainAfterBatch.totalEventsProcessed,
            ~chainId=chain->ChainMap.Chain.toChainId,
          )
        }

        // Calculate and set latency metrics
        switch batch->Batch.findLastEventItem(~chainId=chain->ChainMap.Chain.toChainId) {
        | Some(eventItem) => {
            let blockTimestamp = eventItem.event.block->Types.Block.getTimestamp
            let currentTimeMs = Js.Date.now()->Float.toInt
            let blockTimestampMs = blockTimestamp * 1000
            let latencyMs = currentTimeMs - blockTimestampMs

            Prometheus.ProgressLatency.set(~latencyMs, ~chainId=chain->ChainMap.Chain.toChainId)
          }
        | None => ()
        }

        {
          ...cf,
          // Since we process per chain always in order,
          // we need to calculate it once, by using the first item in a batch
          firstEventBlockNumber: switch cf.firstEventBlockNumber {
          | Some(_) => cf.firstEventBlockNumber
          | None => batch->Batch.findFirstEventBlockNumber(~chainId=chain->ChainMap.Chain.toChainId)
          },
          committedProgressBlockNumber: chainAfterBatch.progressBlockNumber,
          numEventsProcessed: chainAfterBatch.totalEventsProcessed,
          isProgressAtHead: cf.isProgressAtHead || chainAfterBatch.isProgressAtHeadWhenBatchCreated,
          safeCheckpointTracking: switch cf.safeCheckpointTracking {
          | Some(safeCheckpointTracking) =>
            Some(
              safeCheckpointTracking->SafeCheckpointTracking.updateOnNewBatch(
                ~sourceBlockNumber=cf.currentBlockHeight,
                ~chainId=chain->ChainMap.Chain.toChainId,
                ~batchCheckpointIds=batch.checkpointIds,
                ~batchCheckpointBlockNumbers=batch.checkpointBlockNumbers,
                ~batchCheckpointChainIds=batch.checkpointChainIds,
              ),
            )
          | None => None
          },
        }
      }
    | None => cf
    }

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
    } else if cf.timestampCaughtUpToHeadOrEndblock->Option.isNone && cf.isProgressAtHead {
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
        let hasNoMoreEventsToProcess = cf->ChainFetcher.hasNoMoreEventsToProcess

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

  let allChainsSyncedAtHead =
    chainFetchers
    ->ChainMap.values
    ->Array.every(cf => cf.timestampCaughtUpToHeadOrEndblock->Option.isSome)

  if allChainsSyncedAtHead {
    Prometheus.setAllChainsSyncedToHead()
  }

  {
    ...chainManager,
    committedCheckpointId: switch batch.checkpointIds->Utils.Array.last {
    | Some(checkpointId) => checkpointId
    | None => chainManager.committedCheckpointId
    },
    chainFetchers,
  }
}

let validatePartitionQueryResponse = (
  state,
  {chain, response, query} as partitionQueryResponse: partitionQueryResponse,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let {
    parsedQueueItems,
    latestFetchedBlockNumber,
    stats,
    currentBlockHeight,
    reorgGuard,
    fromBlockQueried,
  } = response

  if currentBlockHeight > chainFetcher.currentBlockHeight {
    Prometheus.SourceHeight.set(
      ~blockNumber=currentBlockHeight,
      ~chainId=chainFetcher.chainConfig.id,
      // The currentBlockHeight from response won't necessarily
      // belong to the currently active source.
      // But for simplicity, assume it does.
      ~sourceName=(chainFetcher.sourceManager->SourceManager.getActiveSource).name,
    )
  }

  if Env.Benchmark.shouldSaveData {
    Benchmark.addBlockRangeFetched(
      ~totalTimeElapsed=stats.totalTimeElapsed,
      ~parsingTimeElapsed=stats.parsingTimeElapsed->Belt.Option.getWithDefault(0),
      ~pageFetchTime=stats.pageFetchTime->Belt.Option.getWithDefault(0),
      ~chainId=chain->ChainMap.Chain.toChainId,
      ~fromBlock=fromBlockQueried,
      ~toBlock=latestFetchedBlockNumber,
      ~numEvents=parsedQueueItems->Array.length,
      ~numAddresses=query.addressesByContractName->FetchState.addressesByContractNameCount,
      ~queryName=switch query {
      | {target: Merge(_)} => `Merge Query`
      | {selection: {dependsOnAddresses: false}} => `Wildcard Query`
      | {selection: {dependsOnAddresses: true}} => `Normal Query`
      },
    )
  }

  let (updatedReorgDetection, reorgResult: ReorgDetection.reorgResult) =
    chainFetcher.reorgDetection->ReorgDetection.registerReorgGuard(~reorgGuard, ~currentBlockHeight)

  let updatedChainFetcher = {
    ...chainFetcher,
    reorgDetection: updatedReorgDetection,
  }

  let nextState = {
    ...state,
    chainManager: {
      ...state.chainManager,
      chainFetchers: state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher),
    },
  }

  let rollbackWithReorgDetectedBlockNumber = switch reorgResult {
  | ReorgDetected(reorgDetected) => {
      chainFetcher.logger->Logging.childInfo(
        reorgDetected->ReorgDetection.reorgDetectedToLogParams(
          ~shouldRollbackOnReorg=state.indexer.config.shouldRollbackOnReorg,
        ),
      )
      Prometheus.ReorgCount.increment(~chain)
      Prometheus.ReorgDetectionBlockNumber.set(
        ~blockNumber=reorgDetected.scannedBlock.blockNumber,
        ~chain,
      )
      if state.indexer.config.shouldRollbackOnReorg {
        Some(reorgDetected.scannedBlock.blockNumber)
      } else {
        None
      }
    }
  | NoReorg => None
  }

  switch rollbackWithReorgDetectedBlockNumber {
  | None => (nextState, [ProcessPartitionQueryResponse(partitionQueryResponse)])
  | Some(reorgDetectedBlockNumber) => {
      let chainManager = switch state.rollbackState {
      | RollbackReady({eventsProcessedDiffByChain}) => {
          ...state.chainManager,
          chainFetchers: state.chainManager.chainFetchers->ChainMap.update(chain, chainFetcher => {
            switch eventsProcessedDiffByChain->Utils.Dict.dangerouslyGetByIntNonOption(
              chain->ChainMap.Chain.toChainId,
            ) {
            | Some(eventsProcessedDiff) => {
                ...chainFetcher,
                // Since we detected a reorg, until rollback wasn't completed in the db
                // We return the events processed counter to the pre-rollback value,
                // to decrease it once more for the new rollback.
                numEventsProcessed: chainFetcher.numEventsProcessed + eventsProcessedDiff,
              }
            | None => chainFetcher
            }
          }),
        }
      | _ => state.chainManager
      }
      (
        {
          ...nextState->incrementId,
          chainManager,
          rollbackState: ReorgDetected({
            chain,
            blockNumber: reorgDetectedBlockNumber,
          }),
        },
        [Rollback],
      )
    }
  }
}

let submitPartitionQueryResponse = (
  state,
  ~newItems,
  ~newItemsWithDcs,
  ~currentBlockHeight,
  ~latestFetchedBlock,
  ~query,
  ~chain,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)

  let updatedChainFetcher =
    chainFetcher
    ->ChainFetcher.handleQueryResult(~query, ~latestFetchedBlock, ~newItems, ~newItemsWithDcs)
    ->Utils.unwrapResultExn
    ->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)

  let updatedChainFetcher = {
    ...updatedChainFetcher,
    numBatchesFetched: updatedChainFetcher.numBatchesFetched + 1,
  }

  if !chainFetcher.isProgressAtHead && updatedChainFetcher.isProgressAtHead {
    updatedChainFetcher.logger->Logging.childInfo("All events have been fetched")
  }

  let nextState = {
    ...state,
    chainManager: {
      ...state.chainManager,
      chainFetchers: state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher),
    },
  }

  (
    nextState,
    [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
  )
}

let processPartitionQueryResponse = async (
  state,
  {chain, response, query}: partitionQueryResponse,
  ~dispatchAction,
) => {
  let {
    parsedQueueItems,
    latestFetchedBlockNumber,
    currentBlockHeight,
    latestFetchedBlockTimestamp,
  } = response

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

  let newItemsWithDcs = switch itemsWithContractRegister {
  | [] as empty => empty
  | _ =>
    await ChainFetcher.runContractRegistersOrThrow(
      ~itemsWithContractRegister,
      ~chain,
      ~config=state.indexer.config,
    )
  }

  dispatchAction(
    SubmitPartitionQueryResponse({
      newItems,
      newItemsWithDcs,
      currentBlockHeight,
      latestFetchedBlock: {
        blockNumber: latestFetchedBlockNumber,
        blockTimestamp: latestFetchedBlockTimestamp,
      },
      chain,
      query,
    }),
  )
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

let onEnterReorgThreshold = (~state: t) => {
  Logging.info("Reorg threshold reached")
  Prometheus.ReorgThreshold.set(~isInReorgThreshold=true)

  let chainFetchers = state.chainManager.chainFetchers->ChainMap.map(chainFetcher => {
    {
      ...chainFetcher,
      fetchState: chainFetcher.fetchState->FetchState.updateInternal(
        ~blockLag=Env.indexingBlockLag->Option.getWithDefault(0),
      ),
    }
  })

  {
    ...state,
    chainManager: {
      ...state.chainManager,
      chainFetchers,
      isInReorgThreshold: true,
    },
  }
}

let actionReducer = (state: t, action: action) => {
  switch action {
  | FinishWaitingForNewBlock({chain, currentBlockHeight}) => {
      let isBelowReorgThreshold =
        !state.chainManager.isInReorgThreshold && state.indexer.config.shouldRollbackOnReorg
      let shouldEnterReorgThreshold =
        isBelowReorgThreshold &&
        state.chainManager.chainFetchers
        ->ChainMap.values
        ->Array.every(chainFetcher => {
          chainFetcher.fetchState->FetchState.isReadyToEnterReorgThreshold(~currentBlockHeight)
        })

      let state = {
        ...state,
        chainManager: {
          ...state.chainManager,
          chainFetchers: state.chainManager.chainFetchers->ChainMap.update(chain, chainFetcher => {
            chainFetcher->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)
          }),
        },
      }

      if shouldEnterReorgThreshold {
        (onEnterReorgThreshold(~state), [NextQuery(CheckAllChains)])
      } else {
        (state, [NextQuery(Chain(chain))])
      }
    }
  | ValidatePartitionQueryResponse(partitionQueryResponse) =>
    state->validatePartitionQueryResponse(partitionQueryResponse)
  | SubmitPartitionQueryResponse({
      newItems,
      newItemsWithDcs,
      currentBlockHeight,
      latestFetchedBlock,
      query,
      chain,
    }) =>
    state->submitPartitionQueryResponse(
      ~newItems,
      ~newItemsWithDcs,
      ~currentBlockHeight,
      ~latestFetchedBlock,
      ~query,
      ~chain,
    )
  | EventBatchProcessed({batch}) =>
    let maybePruneEntityHistory =
      state.indexer.config->Config.shouldPruneHistory(
        ~isInReorgThreshold=state.chainManager.isInReorgThreshold,
      )
        ? [PruneStaleEntityHistory]
        : []

    let state = {
      ...state,
      // Can safely reset rollback state, since overwrite is not possible.
      // If rollback is pending, the EventBatchProcessed will be handled by the invalid action reducer instead.
      rollbackState: NoRollback,
      chainManager: state.chainManager->updateProgressedChains(~batch),
      currentlyProcessingBatch: false,
      processedBatches: state.processedBatches + 1,
    }

    let shouldExit = EventProcessing.allChainsEventsProcessedToEndblock(
      state.chainManager.chainFetchers,
    )
      ? {
          Logging.info("All chains are caught up to end blocks.")

          // Keep the indexer process running when in development mode (for Dev Console)
          // or when TUI is enabled (for display)
          if state.keepProcessAlive {
            NoExit
          } else {
            ExitWithSuccess
          }
        }
      : NoExit

    (
      state,
      [UpdateChainMetaDataAndCheckForExit(shouldExit), ProcessEventBatch]->Array.concat(
        maybePruneEntityHistory,
      ),
    )

  | StartProcessingBatch => ({...state, currentlyProcessingBatch: true}, [])
  | StartFindingReorgDepth => ({...state, rollbackState: FindingReorgDepth}, [])
  | FindReorgDepth({chain, rollbackTargetBlockNumber}) => (
      {
        ...state,
        rollbackState: FoundReorgDepth({
          chain,
          rollbackTargetBlockNumber,
        }),
      },
      [Rollback],
    )
  | EnterReorgThreshold => (onEnterReorgThreshold(~state), [NextQuery(CheckAllChains)])
  | UpdateQueues({progressedChainsById, shouldEnterReorgThreshold}) =>
    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      let fs = switch progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
        chain->ChainMap.Chain.toChainId,
      ) {
      | Some(chainAfterBatch) => chainAfterBatch.fetchState
      | None => cf.fetchState
      }
      {
        ...cf,
        fetchState: shouldEnterReorgThreshold
          ? fs->FetchState.updateInternal(~blockLag=Env.indexingBlockLag->Option.getWithDefault(0))
          : fs,
      }
    })

    let chainManager = {
      ...state.chainManager,
      chainFetchers,
    }

    (
      {
        ...state,
        chainManager,
      },
      [NextQuery(CheckAllChains)],
    )
  | SetRollbackState({diffInMemoryStore, rollbackedChainManager, eventsProcessedDiffByChain}) => (
      {
        ...state,
        rollbackState: RollbackReady({
          diffInMemoryStore,
          eventsProcessedDiffByChain,
        }),
        chainManager: rollbackedChainManager,
      },
      [NextQuery(CheckAllChains), ProcessEventBatch],
    )
  | SuccessExit => {
      Logging.info("Exiting with success")
      NodeJs.process->NodeJs.exitWithCode(Success)
      (state, [])
    }
  | ErrorExit(errHandler) =>
    errHandler->ErrorHandling.log
    NodeJs.process->NodeJs.exitWithCode(Failure)
    (state, [])
  }
}

let invalidatedActionReducer = (state: t, action: action) =>
  switch action {
  | EventBatchProcessed({batch}) if state->isPreparingRollback =>
    Logging.info("Finished processing batch before rollback, actioning rollback")
    (
      {
        ...state,
        chainManager: state.chainManager->updateProgressedChains(~batch),
        currentlyProcessingBatch: false,
        processedBatches: state.processedBatches + 1,
      },
      [Rollback],
    )
  | ErrorExit(_) => actionReducer(state, action)
  | _ =>
    Logging.trace({
      "msg": "Invalidated action discarded",
      "action": action->S.convertOrThrow(Utils.Schema.variantTag),
    })
    (state, [])
  }

let checkAndFetchForChain = (
  //Used for dependency injection for tests
  ~waitForNewBlock,
  ~executeQuery,
  //required args
  ~state,
  ~dispatchAction,
) => async chain => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  if !isPreparingRollback(state) {
    let {currentBlockHeight, fetchState} = chainFetcher

    await chainFetcher.sourceManager->SourceManager.fetchNext(
      ~fetchState,
      ~waitForNewBlock=(~currentBlockHeight) =>
        chainFetcher.sourceManager->waitForNewBlock(~currentBlockHeight),
      ~onNewBlock=(~currentBlockHeight) =>
        dispatchAction(FinishWaitingForNewBlock({chain, currentBlockHeight})),
      ~currentBlockHeight,
      ~executeQuery=async query => {
        try {
          let response = await chainFetcher.sourceManager->executeQuery(~query, ~currentBlockHeight)
          dispatchAction(ValidatePartitionQueryResponse({chain, response, query}))
        } catch {
        | exn => dispatchAction(ErrorExit(exn->ErrorHandling.make))
        }
      },
      ~stateId=state.id,
    )
  }
}

let injectedTaskReducer = (
  //Used for dependency injection for tests
  ~waitForNewBlock,
  ~executeQuery,
  ~getLastKnownValidBlock,
) => async (
  //required args
  state: t,
  task: task,
  ~dispatchAction,
) => {
  switch task {
  | ProcessPartitionQueryResponse(partitionQueryResponse) =>
    state->processPartitionQueryResponse(partitionQueryResponse, ~dispatchAction)->Promise.done
  | PruneStaleEntityHistory =>
    let runPrune = async () => {
      switch state.chainManager->ChainManager.getSafeCheckpointId {
      | None => ()
      | Some(safeCheckpointId) =>
        await state.indexer.persistence.sql->InternalTable.Checkpoints.pruneStaleCheckpoints(
          ~pgSchema=Env.Db.publicSchema,
          ~safeCheckpointId,
        )

        for idx in 0 to Entities.allEntities->Array.length - 1 {
          if idx !== 0 {
            // Add some delay between entities
            // To unblock the pg client if it's needed for something else
            await Utils.delay(1000)
          }
          let entityConfig = Entities.allEntities->Array.getUnsafe(idx)
          let timeRef = Hrtime.makeTimer()
          try {
            let () =
              await state.indexer.persistence.sql->EntityHistory.pruneStaleEntityHistory(
                ~entityName=entityConfig.name,
                ~entityIndex=entityConfig.index,
                ~pgSchema=Env.Db.publicSchema,
                ~safeCheckpointId,
              )
          } catch {
          | exn =>
            exn->ErrorHandling.mkLogAndRaise(
              ~msg=`Failed to prune stale entity history`,
              ~logger=Logging.createChild(
                ~params={
                  "entityName": entityConfig.name,
                  "safeCheckpointId": safeCheckpointId,
                },
              ),
            )
          }
          Prometheus.RollbackHistoryPrune.increment(
            ~timeMillis=Hrtime.timeSince(timeRef)->Hrtime.toMillis,
            ~entityName=entityConfig.name,
          )
        }
      }
    }
    state.writeThrottlers.pruneStaleEntityHistory->Throttler.schedule(runPrune)

  | UpdateChainMetaDataAndCheckForExit(shouldExit) =>
    let {chainManager, writeThrottlers} = state
    switch shouldExit {
    | ExitWithSuccess =>
      updateChainMetadataTable(
        chainManager,
        ~throttler=writeThrottlers.chainMetaData,
        ~persistence=state.indexer.persistence,
      )
      dispatchAction(SuccessExit)
    | NoExit =>
      updateChainMetadataTable(
        chainManager,
        ~throttler=writeThrottlers.chainMetaData,
        ~persistence=state.indexer.persistence,
      )->ignore
    }
  | NextQuery(chainCheck) =>
    let fetchForChain = checkAndFetchForChain(
      ~waitForNewBlock,
      ~executeQuery,
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
    if !state.currentlyProcessingBatch && !isPreparingRollback(state) {
      let batch =
        state.chainManager->ChainManager.createBatch(
          ~batchSizeTarget=state.indexer.config.batchSize,
        )

      let progressedChainsById = batch.progressedChainsById
      let totalBatchSize = batch.totalBatchSize

      let isInReorgThreshold = state.chainManager.isInReorgThreshold
      let shouldSaveHistory = state.indexer.config->Config.shouldSaveHistory(~isInReorgThreshold)

      let isBelowReorgThreshold =
        !state.chainManager.isInReorgThreshold && state.indexer.config.shouldRollbackOnReorg
      let shouldEnterReorgThreshold =
        isBelowReorgThreshold &&
        state.chainManager.chainFetchers
        ->ChainMap.values
        ->Array.every(chainFetcher => {
          let fetchState = switch progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
            chainFetcher.fetchState.chainId,
          ) {
          | Some(chainAfterBatch) => chainAfterBatch.fetchState
          | None => chainFetcher.fetchState
          }
          fetchState->FetchState.isReadyToEnterReorgThreshold(
            ~currentBlockHeight=chainFetcher.currentBlockHeight,
          )
        })

      if shouldEnterReorgThreshold {
        dispatchAction(EnterReorgThreshold)
      }

      if progressedChainsById->Utils.Dict.isEmpty {
        ()
      } else {
        if Env.Benchmark.shouldSaveData {
          let group = "Other"
          Benchmark.addSummaryData(
            ~group,
            ~label=`Batch Size`,
            ~value=totalBatchSize->Belt.Int.toFloat,
          )
        }

        dispatchAction(StartProcessingBatch)
        dispatchAction(UpdateQueues({progressedChainsById, shouldEnterReorgThreshold}))

        //In the case of a rollback, use the provided in memory store
        //With rolled back values
        let rollbackInMemStore = switch state.rollbackState {
        | RollbackReady({diffInMemoryStore}) => Some(diffInMemoryStore)
        | _ => None
        }

        let inMemoryStore = rollbackInMemStore->Option.getWithDefault(InMemoryStore.make(~entities=Entities.allEntities))

        inMemoryStore->InMemoryStore.setBatchDcs(~batch, ~shouldSaveHistory)

        switch await EventProcessing.processEventBatch(
          ~batch,
          ~inMemoryStore,
          ~isInReorgThreshold,
          ~loadManager=state.loadManager,
          ~indexer=state.indexer,
          ~chainFetchers=state.chainManager.chainFetchers,
        ) {
        | exception exn =>
          //All casese should be handled/caught before this with better user messaging.
          //This is just a safety in case something unexpected happens
          let errHandler =
            exn->ErrorHandling.make(~msg="A top level unexpected error occurred during processing")
          dispatchAction(ErrorExit(errHandler))
        | res =>
          switch res {
          | Ok() => dispatchAction(EventBatchProcessed({batch: batch}))
          | Error(errHandler) => dispatchAction(ErrorExit(errHandler))
          }
        }
      }
    }
  | Rollback =>
    //If it isn't processing a batch currently continue with rollback otherwise wait for current batch to finish processing
    switch state {
    | {rollbackState: NoRollback | RollbackReady(_)} =>
      Js.Exn.raiseError("Internal error: Rollback initiated with invalid state")
    | {rollbackState: ReorgDetected({chain, blockNumber: reorgBlockNumber})} => {
        let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)

        dispatchAction(StartFindingReorgDepth)
        let rollbackTargetBlockNumber =
          await chainFetcher->getLastKnownValidBlock(~reorgBlockNumber)

        dispatchAction(FindReorgDepth({chain, rollbackTargetBlockNumber}))
      }
    // We can come to this case when event batch finished processing
    // while we are still finding the reorg depth
    // Do nothing here, just wait for reorg depth to be found
    | {rollbackState: FindingReorgDepth} => ()
    | {rollbackState: FoundReorgDepth(_), currentlyProcessingBatch: true} =>
      Logging.info("Waiting for batch to finish processing before executing rollback")
    | {rollbackState: FoundReorgDepth({chain: reorgChain, rollbackTargetBlockNumber})} =>
      let startTime = Hrtime.makeTimer()

      let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(reorgChain)

      let logger = Logging.createChildFrom(
        ~logger=chainFetcher.logger,
        ~params={
          "action": "Rollback",
          "reorgChain": reorgChain,
          "targetBlockNumber": rollbackTargetBlockNumber,
        },
      )
      logger->Logging.childInfo("Started rollback on reorg")
      Prometheus.RollbackTargetBlockNumber.set(
        ~blockNumber=rollbackTargetBlockNumber,
        ~chain=reorgChain,
      )

      let reorgChainId = reorgChain->ChainMap.Chain.toChainId

      let rollbackTargetCheckpointId = {
        switch await state.indexer.persistence.sql->InternalTable.Checkpoints.getRollbackTargetCheckpoint(
          ~pgSchema=Env.Db.publicSchema,
          ~reorgChainId,
          ~lastKnownValidBlockNumber=rollbackTargetBlockNumber,
        ) {
        | [checkpoint] => checkpoint["id"]
        | _ => 0
        }
      }

      let eventsProcessedDiffByChain = Js.Dict.empty()
      let newProgressBlockNumberPerChain = Js.Dict.empty()
      let rollbackedProcessedEvents = ref(0)

      {
        let rollbackProgressDiff =
          await state.indexer.persistence.sql->InternalTable.Checkpoints.getRollbackProgressDiff(
            ~pgSchema=Env.Db.publicSchema,
            ~rollbackTargetCheckpointId,
          )
        for idx in 0 to rollbackProgressDiff->Js.Array2.length - 1 {
          let diff = rollbackProgressDiff->Js.Array2.unsafe_get(idx)
          eventsProcessedDiffByChain->Utils.Dict.setByInt(
            diff["chain_id"],
            switch diff["events_processed_diff"]->Int.fromString {
            | Some(eventsProcessedDiff) => {
                rollbackedProcessedEvents :=
                  rollbackedProcessedEvents.contents + eventsProcessedDiff
                eventsProcessedDiff
              }
            | None =>
              Js.Exn.raiseError(
                `Unexpedted case: Invalid events processed diff ${diff["events_processed_diff"]}`,
              )
            },
          )
          newProgressBlockNumberPerChain->Utils.Dict.setByInt(
            diff["chain_id"],
            if rollbackTargetCheckpointId === 0 && diff["chain_id"] === reorgChainId {
              Pervasives.min(diff["new_progress_block_number"], rollbackTargetBlockNumber)
            } else {
              diff["new_progress_block_number"]
            },
          )
        }
      }

      let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
        switch newProgressBlockNumberPerChain->Utils.Dict.dangerouslyGetByIntNonOption(
          chain->ChainMap.Chain.toChainId,
        ) {
        | Some(newProgressBlockNumber) =>
          let fetchState =
            cf.fetchState->FetchState.rollback(~targetBlockNumber=newProgressBlockNumber)
          let newTotalEventsProcessed =
            cf.numEventsProcessed -
            eventsProcessedDiffByChain
            ->Utils.Dict.dangerouslyGetByIntNonOption(chain->ChainMap.Chain.toChainId)
            ->Option.getUnsafe

          if cf.committedProgressBlockNumber !== newProgressBlockNumber {
            Prometheus.ProgressBlockNumber.set(
              ~blockNumber=newProgressBlockNumber,
              ~chainId=chain->ChainMap.Chain.toChainId,
            )
          }
          if cf.numEventsProcessed !== newTotalEventsProcessed {
            Prometheus.ProgressEventsCount.set(
              ~processedCount=newTotalEventsProcessed,
              ~chainId=chain->ChainMap.Chain.toChainId,
            )
          }

          {
            ...cf,
            reorgDetection: chain == reorgChain
              ? cf.reorgDetection->ReorgDetection.rollbackToValidBlockNumber(
                  ~blockNumber=rollbackTargetBlockNumber,
                )
              : cf.reorgDetection,
            safeCheckpointTracking: switch cf.safeCheckpointTracking {
            | Some(safeCheckpointTracking) =>
              Some(
                safeCheckpointTracking->SafeCheckpointTracking.rollback(
                  ~targetBlockNumber=newProgressBlockNumber,
                ),
              )
            | None => None
            },
            fetchState,
            committedProgressBlockNumber: newProgressBlockNumber,
            numEventsProcessed: newTotalEventsProcessed,
          }

        | None => //If no change was produced on the given chain after the reorged chain, no need to rollback anything
          cf
        }
      })

      // Construct in Memory store with rollback diff
      let diff = await IO.prepareRollbackDiff(
        ~rollbackTargetCheckpointId,
        ~persistence=state.indexer.persistence,
      )

      let chainManager = {
        ...state.chainManager,
        committedCheckpointId: rollbackTargetCheckpointId,
        chainFetchers,
      }

      logger->Logging.childTrace({
        "msg": "Finished rollback on reorg",
        "entityChanges": {
          "deleted": diff["deletedEntities"],
          "upserted": diff["setEntities"],
        },
        "rollbackedEvents": rollbackedProcessedEvents.contents,
        "beforeCheckpointId": state.chainManager.committedCheckpointId,
        "targetCheckpointId": rollbackTargetCheckpointId,
      })
      Prometheus.RollbackSuccess.increment(
        ~timeMillis=Hrtime.timeSince(startTime)->Hrtime.toMillis,
        ~rollbackedProcessedEvents=rollbackedProcessedEvents.contents,
      )

      dispatchAction(
        SetRollbackState({
          diffInMemoryStore: diff["inMemStore"],
          rollbackedChainManager: chainManager,
          eventsProcessedDiffByChain,
        }),
      )
    }
  }
}

let taskReducer = injectedTaskReducer(
  ~waitForNewBlock=SourceManager.waitForNewBlock,
  ~executeQuery=SourceManager.executeQuery,
  ~getLastKnownValidBlock=(chainFetcher, ~reorgBlockNumber) =>
    chainFetcher->ChainFetcher.getLastKnownValidBlock(~reorgBlockNumber),
)
