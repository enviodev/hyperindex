open Belt

type chain = ChainMap.Chain.t
type rollbackState = NoRollback | RollingBack(chain) | RollbackInMemStore(InMemoryStore.t)

module WriteThrottlers = {
  type t = {
    chainMetaData: Throttler.t,
    pruneStaleEndBlockData: ChainMap.t<Throttler.t>,
    pruneStaleEntityHistory: Throttler.t,
  }
  let make = (~config: Config.t): t => {
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

    let pruneStaleEndBlockData = config.chainMap->ChainMap.map(cfg => {
      let intervalMillis = Env.ThrottleWrites.pruneStaleDataIntervalMillis
      let logger = Logging.createChild(
        ~params={
          "context": "Throttler for pruning stale endblock data",
          "intervalMillis": intervalMillis,
          "chain": cfg.id,
        },
      )
      Throttler.make(~intervalMillis, ~logger)
    })

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
    {chainMetaData, pruneStaleEndBlockData, pruneStaleEntityHistory}
  }
}

type t = {
  config: Config.t,
  chainManager: ChainManager.t,
  processedBatches: int,
  currentlyProcessingBatch: bool,
  rollbackState: rollbackState,
  indexerStartTime: Js.Date.t,
  writeThrottlers: WriteThrottlers.t,
  loadManager: LoadManager.t,
  shouldUseTui: bool,
  //Initialized as 0, increments, when rollbacks occur to invalidate
  //responses based on the wrong stateId
  id: int,
}

let make = (~config: Config.t, ~chainManager: ChainManager.t, ~shouldUseTui=false) => {
  {
    config,
    currentlyProcessingBatch: false,
    processedBatches: 0,
    chainManager,
    indexerStartTime: Js.Date.make(),
    rollbackState: NoRollback,
    writeThrottlers: WriteThrottlers.make(~config),
    loadManager: LoadManager.make(),
    shouldUseTui,
    id: 0,
  }
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
      dynamicContracts: array<FetchState.indexingContract>,
      currentBlockHeight: int,
      latestFetchedBlock: FetchState.blockNumberAndTimestamp,
      query: FetchState.query,
      chain: chain,
    })
  | FinishWaitingForNewBlock({chain: chain, currentBlockHeight: int})
  | EventBatchProcessed({
      progressedChains: array<Batch.progressedChain>,
      items: array<Internal.item>,
    })
  | StartProcessingBatch
  | EnterReorgThreshold
  | UpdateQueues({
      updatedFetchStates: ChainMap.t<FetchState.t>,
      // Needed to prevent overwriting the blockLag
      // set by EnterReorgThreshold
      shouldEnterReorgThreshold: bool,
    })
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
      nextEndOfBlockRangeScannedData: DbFunctions.EndOfBlockRangeScannedData.endOfBlockRangeScannedData,
    })
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

let updateChainMetadataTable = (cm: ChainManager.t, ~throttler: Throttler.t) => {
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
    Db.sql
    ->InternalTable.Chains.setMeta(~pgSchema=Db.publicSchema, ~chainsData)
    ->Promise.ignoreValue
  )
}

/**
Takes in a chain manager and sets all chains timestamp caught up to head
when valid state lines up and returns an updated chain manager
*/
let updateProgressedChains = (
  chainManager: ChainManager.t,
  ~progressedChains: array<Batch.progressedChain>,
  ~items: array<Internal.item>,
) => {
  let nextQueueItemIsNone = chainManager->ChainManager.nextItemIsNone

  let allChainsAtHead = chainManager->ChainManager.isProgressAtHead
  //Update the timestampCaughtUpToHeadOrEndblock values
  let chainFetchers = chainManager.chainFetchers->ChainMap.map(cf => {
    let chain = ChainMap.Chain.makeUnsafe(~chainId=cf.chainConfig.id)

    let maybeProgressData =
      progressedChains->Js.Array2.find(progressedChain =>
        progressedChain.chainId === chain->ChainMap.Chain.toChainId
      )

    let cf = switch maybeProgressData {
    | Some(progressData) => {
        if cf.committedProgressBlockNumber !== progressData.progressBlockNumber {
          Prometheus.ProgressBlockNumber.set(
            ~blockNumber=progressData.progressBlockNumber,
            ~chainId=chain->ChainMap.Chain.toChainId,
          )
        }
        if cf.numEventsProcessed !== progressData.totalEventsProcessed {
          Prometheus.ProgressEventsCount.set(
            ~processedCount=progressData.totalEventsProcessed,
            ~chainId=chain->ChainMap.Chain.toChainId,
          )
        }
        {
          ...cf,
          // Since we process per chain always in order,
          // we need to calculate it once, by using the first item in a batch
          firstEventBlockNumber: switch cf.firstEventBlockNumber {
          | Some(_) => cf.firstEventBlockNumber
          | None =>
            switch items->Js.Array2.find(item =>
              switch item {
              | Internal.Event({chain: eventChain}) => eventChain === chain
              | Internal.Block({onBlockConfig: {chainId}}) =>
                chainId === chain->ChainMap.Chain.toChainId
              }
            ) {
            | Some(item) => Some(item->Internal.getItemBlockNumber)
            | None => None
            }
          },
          isProgressAtHead: cf.isProgressAtHead || progressData.isProgressAtHead,
          committedProgressBlockNumber: progressData.progressBlockNumber,
          numEventsProcessed: progressData.totalEventsProcessed,
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
  let {rangeLastBlock} = reorgGuard

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

  let (updatedLastBlockScannedHashes, reorgResult) =
    chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
      ~reorgGuard,
      ~currentBlockHeight,
      ~shouldRollbackOnReorg=state.config->Config.shouldRollbackOnReorg,
    )

  let updatedChainFetcher = {
    ...chainFetcher,
    lastBlockScannedHashes: updatedLastBlockScannedHashes,
  }

  let nextState = {
    ...state,
    chainManager: {
      ...state.chainManager,
      chainFetchers: state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher),
    },
  }

  let isRollback = switch reorgResult {
  | ReorgDetected(reorgDetected) => {
      chainFetcher.logger->Logging.childInfo(
        reorgDetected->ReorgDetection.reorgDetectedToLogParams(
          ~shouldRollbackOnReorg=state.config->Config.shouldRollbackOnReorg,
        ),
      )
      Prometheus.ReorgCount.increment(~chain)
      Prometheus.ReorgDetectionBlockNumber.set(
        ~blockNumber=reorgDetected.scannedBlock.blockNumber,
        ~chain,
      )
      state.config->Config.shouldRollbackOnReorg
    }
  | NoReorg => false
  }

  if isRollback {
    (nextState->incrementId->setRollingBack(chain), [Rollback])
  } else {
    let updateEndOfBlockRangeScannedDataArr =
      //Only update endOfBlockRangeScannedData if rollbacks are enabled
      state.config->Config.shouldRollbackOnReorg
        ? [
            UpdateEndOfBlockRangeScannedData({
              chain,
              blockNumberThreshold: rangeLastBlock.blockNumber -
              updatedChainFetcher.chainConfig.confirmedBlockThreshold,
              nextEndOfBlockRangeScannedData: {
                chainId: chain->ChainMap.Chain.toChainId,
                blockNumber: rangeLastBlock.blockNumber,
                blockHash: rangeLastBlock.blockHash,
              },
            }),
          ]
        : []

    (
      nextState,
      Array.concat(
        updateEndOfBlockRangeScannedDataArr,
        [ProcessPartitionQueryResponse(partitionQueryResponse)],
      ),
    )
  }
}

let submitPartitionQueryResponse = (
  state,
  ~newItems,
  ~dynamicContracts,
  ~currentBlockHeight,
  ~latestFetchedBlock,
  ~query,
  ~chain,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)

  let updatedChainFetcher =
    chainFetcher
    ->ChainFetcher.handleQueryResult(~query, ~latestFetchedBlock, ~newItems, ~dynamicContracts)
    ->Utils.unwrapResultExn
    ->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)

  let updatedChainFetcher = {
    ...updatedChainFetcher,
    numBatchesFetched: updatedChainFetcher.numBatchesFetched + 1,
  }

  let wasFetchingAtHead = chainFetcher.isProgressAtHead
  let isCurrentlyFetchingAtHead = updatedChainFetcher.isProgressAtHead

  if !wasFetchingAtHead && isCurrentlyFetchingAtHead {
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
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
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
    if (
      switch chainFetcher.processingFilters {
      | None => true
      | Some(processingFilters) => ChainFetcher.applyProcessingFilters(~item, ~processingFilters)
      }
    ) {
      if eventItem.eventConfig.contractRegister !== None {
        itemsWithContractRegister->Array.push(item)
      }

      // TODO: Don't really need to keep it in the queue
      // when there's no handler (besides raw_events, processed counter, and dcsToStore consuming)
      newItems->Array.push(item)
    }
  }

  let dynamicContracts = switch itemsWithContractRegister {
  | [] as empty =>
    // A small optimisation to not recreate an empty array
    empty->(Utils.magic: array<Internal.item> => array<FetchState.indexingContract>)
  | _ =>
    await ChainFetcher.runContractRegistersOrThrow(
      ~itemsWithContractRegister,
      ~chain,
      ~config=state.config,
    )
  }

  dispatchAction(
    SubmitPartitionQueryResponse({
      newItems,
      dynamicContracts,
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

let actionReducer = (state: t, action: action) => {
  switch action {
  | FinishWaitingForNewBlock({chain, currentBlockHeight}) => {
      let isInReorgThreshold = state.chainManager.isInReorgThreshold
      let isBelowReorgThreshold = !isInReorgThreshold && state.config->Config.shouldRollbackOnReorg
      let shouldEnterReorgThreshold =
        isBelowReorgThreshold &&
        state.chainManager.chainFetchers
        ->ChainMap.values
        ->Array.every(chainFetcher => {
          chainFetcher.fetchState->FetchState.isReadyToEnterReorgThreshold(~currentBlockHeight)
        })

      (
        {
          ...state,
          chainManager: {
            ...state.chainManager,
            isInReorgThreshold: isInReorgThreshold || shouldEnterReorgThreshold,
            chainFetchers: state.chainManager.chainFetchers->ChainMap.update(
              chain,
              chainFetcher => {
                if shouldEnterReorgThreshold {
                  {
                    ...chainFetcher,
                    fetchState: chainFetcher.fetchState->FetchState.updateInternal(
                      ~blockLag=Env.indexingBlockLag->Option.getWithDefault(0),
                    ),
                  }
                } else {
                  chainFetcher
                }->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)
              },
            ),
          },
        },
        [NextQuery(Chain(chain))],
      )
    }
  | ValidatePartitionQueryResponse(partitionQueryResponse) =>
    state->validatePartitionQueryResponse(partitionQueryResponse)
  | SubmitPartitionQueryResponse({
      newItems,
      dynamicContracts,
      currentBlockHeight,
      latestFetchedBlock,
      query,
      chain,
    }) =>
    state->submitPartitionQueryResponse(
      ~newItems,
      ~dynamicContracts,
      ~currentBlockHeight,
      ~latestFetchedBlock,
      ~query,
      ~chain,
    )
  | EventBatchProcessed({progressedChains, items}) =>
    let maybePruneEntityHistory =
      state.config->Config.shouldPruneHistory(
        ~isInReorgThreshold=state.chainManager.isInReorgThreshold,
      )
        ? [PruneStaleEntityHistory]
        : []

    let state = {
      ...state,
      chainManager: state.chainManager->updateProgressedChains(~progressedChains, ~items),
      currentlyProcessingBatch: false,
      processedBatches: state.processedBatches + 1,
    }

    let shouldExit = EventProcessing.allChainsEventsProcessedToEndblock(
      state.chainManager.chainFetchers,
    )
      ? {
          // state.config.persistence.storage
          Logging.info("All chains are caught up to end blocks.")

          // Keep the indexer process running in TUI mode
          // so the Dev Console server stays working
          if state.shouldUseTui {
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
  | EnterReorgThreshold =>
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

    (
      {
        ...state,
        chainManager: {
          ...state.chainManager,
          chainFetchers,
          isInReorgThreshold: true,
        },
      },
      [NextQuery(CheckAllChains)],
    )
  | UpdateQueues({updatedFetchStates, shouldEnterReorgThreshold}) =>
    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      let fs = ChainMap.get(updatedFetchStates, chain)
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
  | SetRollbackState(inMemoryStore, chainManager) => (
      {...state, rollbackState: RollbackInMemStore(inMemoryStore), chainManager},
      [NextQuery(CheckAllChains), ProcessEventBatch],
    )
  | ResetRollbackState => ({...state, rollbackState: NoRollback}, [])
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
  switch (state, action) {
  | ({rollbackState: RollingBack(_)}, EventBatchProcessed(_)) =>
    Logging.info("Finished processing batch before rollback, actioning rollback")
    (
      {...state, currentlyProcessingBatch: false, processedBatches: state.processedBatches + 1},
      [Rollback],
    )
  | (_, ErrorExit(_)) => actionReducer(state, action)
  | _ =>
    Logging.info({
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
  if !isRollingBack(state) {
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
  | UpdateEndOfBlockRangeScannedData({
      chain,
      blockNumberThreshold,
      nextEndOfBlockRangeScannedData,
    }) =>
    let timeRef = Hrtime.makeTimer()
    await Db.sql->DbFunctions.EndOfBlockRangeScannedData.setEndOfBlockRangeScannedData(
      nextEndOfBlockRangeScannedData,
    )

    if Env.Benchmark.shouldSaveData {
      let elapsedTimeMillis = Hrtime.timeSince(timeRef)->Hrtime.toMillis->Hrtime.intFromMillis
      Benchmark.addSummaryData(
        ~group="Other",
        ~label=`Chain ${chain->ChainMap.Chain.toString} UpdateEndOfBlockRangeScannedData (ms)`,
        ~value=elapsedTimeMillis->Belt.Int.toFloat,
      )
    }

    //These prune functions can be scheduled and throttled if a more recent prune function gets called
    //before the current one is executed
    let runPrune = async () => {
      let timeRef = Hrtime.makeTimer()
      await Db.sql->DbFunctions.EndOfBlockRangeScannedData.deleteStaleEndOfBlockRangeScannedDataForChain(
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~blockNumberThreshold,
      )

      if Env.Benchmark.shouldSaveData {
        let elapsedTimeMillis = Hrtime.timeSince(timeRef)->Hrtime.toMillis->Hrtime.intFromMillis
        Benchmark.addSummaryData(
          ~group="Other",
          ~label=`Chain ${chain->ChainMap.Chain.toString} PruneStaleData (ms)`,
          ~value=elapsedTimeMillis->Belt.Int.toFloat,
        )
      }
    }

    let throttler = state.writeThrottlers.pruneStaleEndBlockData->ChainMap.get(chain)
    throttler->Throttler.schedule(runPrune)
  | PruneStaleEntityHistory =>
    let runPrune = async () => {
      let safeReorgBlocks = state.chainManager->ChainManager.getSafeReorgBlocks

      if safeReorgBlocks.chainIds->Utils.Array.notEmpty {
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
              await Db.sql->EntityHistory.pruneStaleEntityHistory(
                ~entityName=entityConfig.name,
                ~pgSchema=Env.Db.publicSchema,
                ~safeReorgBlocks,
              )
          } catch {
          | exn =>
            exn->ErrorHandling.mkLogAndRaise(
              ~msg=`Failed to prune stale entity history`,
              ~logger=Logging.createChild(
                ~params={
                  "entityName": entityConfig.name,
                  "safeBlockNumbers": safeReorgBlocks.chainIds
                  ->Js.Array2.mapi((chainId, idx) => (
                    chainId->Belt.Int.toString,
                    safeReorgBlocks.blockNumbers->Js.Array2.unsafe_get(idx),
                  ))
                  ->Js.Dict.fromArray,
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
      updateChainMetadataTable(chainManager, ~throttler=writeThrottlers.chainMetaData)
      dispatchAction(SuccessExit)
    | NoExit =>
      updateChainMetadataTable(chainManager, ~throttler=writeThrottlers.chainMetaData)->ignore
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
    if !state.currentlyProcessingBatch && !isRollingBack(state) {
      let batch =
        state.chainManager->ChainManager.createBatch(~batchSizeTarget=state.config.batchSize)

      let updatedFetchStates = batch.updatedFetchStates

      let isInReorgThreshold = state.chainManager.isInReorgThreshold
      let isBelowReorgThreshold =
        !state.chainManager.isInReorgThreshold && state.config->Config.shouldRollbackOnReorg
      let shouldEnterReorgThreshold =
        isBelowReorgThreshold &&
        updatedFetchStates
        ->ChainMap.keys
        ->Array.every(chain => {
          updatedFetchStates
          ->ChainMap.get(chain)
          ->FetchState.isReadyToEnterReorgThreshold(
            ~currentBlockHeight=(
              state.chainManager.chainFetchers->ChainMap.get(chain)
            ).currentBlockHeight,
          )
        })
      if shouldEnterReorgThreshold {
        dispatchAction(EnterReorgThreshold)
      }

      switch batch {
      | {progressedChains: []} => ()
      | {items: [], progressedChains} =>
        dispatchAction(StartProcessingBatch)
        // For this case there shouldn't be any FetchState changes
        // so we don't dispatch UpdateQueues - only update the progress for chains without events
        await Db.sql->InternalTable.Chains.setProgressedChains(
          ~pgSchema=Db.publicSchema,
          ~progressedChains,
        )
        // FIXME: When state.rollbackState is RollbackInMemStore
        // If we increase progress in this case (no items)
        // and then indexer restarts - there's a high chance of missing
        // the rollback. This should be tested and fixed.
        dispatchAction(EventBatchProcessed({progressedChains, items: batch.items}))
      | {items, progressedChains, updatedFetchStates, dcsToStoreByChainId} =>
        if Env.Benchmark.shouldSaveData {
          let group = "Other"
          Benchmark.addSummaryData(
            ~group,
            ~label=`Batch Creation Time (ms)`,
            ~value=batch.creationTimeMs->Belt.Int.toFloat,
          )
          Benchmark.addSummaryData(
            ~group,
            ~label=`Batch Size`,
            ~value=items->Array.length->Belt.Int.toFloat,
          )
        }

        dispatchAction(StartProcessingBatch)
        dispatchAction(UpdateQueues({updatedFetchStates, shouldEnterReorgThreshold}))

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

        if dcsToStoreByChainId->Utils.Dict.size > 0 {
          let shouldSaveHistory = state.config->Config.shouldSaveHistory(~isInReorgThreshold)
          inMemoryStore->InMemoryStore.setDcsToStore(dcsToStoreByChainId, ~shouldSaveHistory)
        }

        state.chainManager.chainFetchers
        ->ChainMap.keys
        ->Array.forEach(chain => {
          let chainId = chain->ChainMap.Chain.toChainId
          switch progressedChains->Js.Array2.find(progressedChain =>
            progressedChain.chainId === chainId
          ) {
          | Some(progressData) =>
            Prometheus.ProcessingBatchSize.set(~batchSize=progressData.batchSize, ~chainId)
            Prometheus.ProcessingBlockNumber.set(
              ~blockNumber=progressData.progressBlockNumber,
              ~chainId,
            )
          | None => Prometheus.ProcessingBatchSize.set(~batchSize=0, ~chainId)
          }
        })

        switch await EventProcessing.processEventBatch(
          ~items,
          ~progressedChains,
          ~inMemoryStore,
          ~isInReorgThreshold,
          ~loadManager=state.loadManager,
          ~config=state.config,
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
          | Ok() => dispatchAction(EventBatchProcessed({progressedChains, items}))
          | Error(errHandler) => dispatchAction(ErrorExit(errHandler))
          }
        }
      }
    }
  | Rollback =>
    //If it isn't processing a batch currently continue with rollback otherwise wait for current batch to finish processing
    switch state {
    | {currentlyProcessingBatch: false, rollbackState: RollingBack(reorgChain)} =>
      let startTime = Hrtime.makeTimer()

      let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(reorgChain)

      let {
        blockNumber: lastKnownValidBlockNumber,
        blockTimestamp: lastKnownValidBlockTimestamp,
      }: ReorgDetection.blockDataWithTimestamp =
        await chainFetcher->getLastKnownValidBlock

      let logger = Logging.createChildFrom(
        ~logger=chainFetcher.logger,
        ~params={
          "action": "Rollback",
          "reorgChain": reorgChain,
          "targetBlockNumber": lastKnownValidBlockNumber,
          "targetBlockTimestamp": lastKnownValidBlockTimestamp,
        },
      )
      logger->Logging.childInfo("Started rollback on reorg")
      Prometheus.RollbackTargetBlockNumber.set(
        ~blockNumber=lastKnownValidBlockNumber,
        ~chain=reorgChain,
      )

      let reorgChainId = reorgChain->ChainMap.Chain.toChainId

      //Get the first change event that occurred on each chain after the last known valid block
      //Uses a different method depending on if the reorg chain is ordered or unordered
      let firstChangeEventIdentifierPerChain =
        await Db.sql->DbFunctions.EntityHistory.getFirstChangeEventPerChain(
          switch state.config.multichain {
          | Unordered =>
            UnorderedMultichain({
              reorgChainId,
              safeBlockNumber: lastKnownValidBlockNumber,
            })
          | Ordered =>
            OrderedMultichain({
              safeBlockTimestamp: lastKnownValidBlockTimestamp,
              reorgChainId,
              safeBlockNumber: lastKnownValidBlockNumber,
            })
          },
        )

      firstChangeEventIdentifierPerChain->DbFunctions.EntityHistory.FirstChangeEventPerChain.setIfEarlier(
        ~chainId=reorgChainId,
        ~event={
          blockNumber: lastKnownValidBlockNumber + 1,
          logIndex: 0,
        },
      )

      let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
        switch firstChangeEventIdentifierPerChain->DbFunctions.EntityHistory.FirstChangeEventPerChain.get(
          ~chainId=chain->ChainMap.Chain.toChainId,
        ) {
        | Some(firstChangeEvent) =>
          let fetchState = cf.fetchState->FetchState.rollback(~firstChangeEvent)

          let rolledBackCf = {
            ...cf,
            lastBlockScannedHashes: chain == reorgChain
              ? cf.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.rollbackToValidBlockNumber(
                  ~blockNumber=lastKnownValidBlockNumber,
                )
              : cf.lastBlockScannedHashes,
            fetchState,
          }
          //On other chains, filter out evennts based on the first change present on the chain after the reorg
          rolledBackCf->ChainFetcher.addProcessingFilter(
            ~filter=item => {
              switch item {
              | Internal.Event({blockNumber, logIndex})
              | Internal.Block({blockNumber, logIndex}) =>
                //Filter out events that occur passed the block where the query starts but
                //are lower than the timestamp where we rolled back to
                (blockNumber, logIndex) >= (firstChangeEvent.blockNumber, firstChangeEvent.logIndex)
              }
            },
            ~isValid=(~fetchState) => {
              //Remove the event filter once the fetchState has fetched passed the
              //blockNumber of the valid first change event
              fetchState->FetchState.bufferBlockNumber <= firstChangeEvent.blockNumber
            },
          )
        | None => //If no change was produced on the given chain after the reorged chain, no need to rollback anything
          cf
        }
      })

      //Construct a rolledback in Memory store
      let rollbackResult = await IO.RollBack.rollBack(
        ~chainId=reorgChain->ChainMap.Chain.toChainId,
        ~blockTimestamp=lastKnownValidBlockTimestamp,
        ~blockNumber=lastKnownValidBlockNumber,
        ~logIndex=0,
        ~isUnorderedMultichainMode=switch state.config.multichain {
        | Unordered => true
        | Ordered => false
        },
      )

      let chainManager = {
        ...state.chainManager,
        chainFetchers,
      }

      logger->Logging.childTrace({
        "msg": "Finished rollback on reorg",
        "entityChanges": {
          "deleted": rollbackResult["deletedEntities"],
          "upserted": rollbackResult["setEntities"],
        },
      })
      logger->Logging.childTrace({
        "msg": "Initial diff of rollback entity history",
        "diff": rollbackResult["fullDiff"],
      })
      Prometheus.RollbackSuccess.increment(~timeMillis=Hrtime.timeSince(startTime)->Hrtime.toMillis)

      dispatchAction(SetRollbackState(rollbackResult["inMemStore"], chainManager))

    | _ => Logging.info("Waiting for batch to finish processing before executing rollback") //wait for batch to finish processing
    }
  }
}

let taskReducer = injectedTaskReducer(
  ~waitForNewBlock=SourceManager.waitForNewBlock,
  ~executeQuery=SourceManager.executeQuery,
  ~getLastKnownValidBlock=ChainFetcher.getLastKnownValidBlock(_),
)
