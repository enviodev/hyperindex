open Belt

type chain = ChainMap.Chain.t
type rollbackState = NoRollback | RollingBack(chain) | RollbackInMemStore(InMemoryStore.t)

module WriteThrottlers = {
  type t = {
    chainMetaData: Throttler.t,
    pruneStaleEndBlockData: ChainMap.t<Throttler.t>,
    pruneStaleEntityHistory: Throttler.t,
    mutable deepCleanCount: int,
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
          "chain": cfg.chain,
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
    {chainMetaData, pruneStaleEndBlockData, pruneStaleEntityHistory, deepCleanCount: 0}
  }
}

type t = {
  config: Config.t,
  chainManager: ChainManager.t,
  currentlyProcessingBatch: bool,
  rollbackState: rollbackState,
  maxBatchSize: int,
  maxPerChainQueueSize: int,
  indexerStartTime: Js.Date.t,
  writeThrottlers: WriteThrottlers.t,
  loadLayer: LoadLayer.t,
  shouldUseTui: bool,
  //Initialized as 0, increments, when rollbacks occur to invalidate
  //responses based on the wrong stateId
  id: int,
}

let make = (
  ~config: Config.t,
  ~chainManager: ChainManager.t,
  ~loadLayer: LoadLayer.t,
  ~shouldUseTui=false,
) => {
  let maxPerChainQueueSize = {
    let numChains = config.chainMap->ChainMap.size
    Env.maxEventFetchedQueueSize / numChains
  }
  config.chainMap
  ->ChainMap.keys
  ->Array.forEach(chain => {
    Prometheus.IndexingMaxBufferSize.set(
      ~maxBufferSize=maxPerChainQueueSize,
      ~chainId=chain->ChainMap.Chain.toChainId,
    )
  })
  {
    config,
    currentlyProcessingBatch: false,
    chainManager,
    maxBatchSize: Env.maxProcessBatchSize,
    maxPerChainQueueSize,
    indexerStartTime: Js.Date.make(),
    rollbackState: NoRollback,
    writeThrottlers: WriteThrottlers.make(~config),
    loadLayer,
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

type shouldExit = ExitWithSuccess | NoExit
type action =
  | PartitionQueryResponse({
      chain: chain,
      response: Source.blockRangeFetchResponse,
      query: FetchState.query,
    })
  | FinishWaitingForNewBlock({chain: chain, currentBlockHeight: int})
  | EventBatchProcessed(EventProcessing.EventsProcessed.t)
  | SetCurrentlyProcessing(bool)
  | SetIsInReorgThreshold(bool)
  | UpdateQueues(ChainMap.t<ChainManager.fetchStateWithData>)
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
      nextEndOfBlockRangeScannedData: DbFunctions.EndOfBlockRangeScannedData.endOfBlockRangeScannedData,
    })
  | ProcessEventBatch
  | UpdateChainMetaDataAndCheckForExit(shouldExit)
  | Rollback
  | PruneStaleEntityHistory

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

let updateChainMetadataTable = async (cm: ChainManager.t, ~throttler: Throttler.t) => {
  let chainMetadataArray: array<DbFunctions.ChainMetadata.chainMetadata> =
    cm.chainFetchers
    ->ChainMap.values
    ->Belt.Array.map(cf => {
      let latestFetchedBlock = cf.fetchState->FetchState.getLatestFullyFetchedBlock
      let chainMetadata: DbFunctions.ChainMetadata.chainMetadata = {
        chainId: cf.chainConfig.chain->ChainMap.Chain.toChainId,
        startBlock: cf.chainConfig.startBlock,
        blockHeight: cf.currentBlockHeight,
        //optional fields
        endBlock: cf.chainConfig.endBlock->Js.Nullable.fromOption, //this is already optional
        firstEventBlockNumber: cf->ChainFetcher.getFirstEventBlockNumber->Js.Nullable.fromOption,
        latestProcessedBlock: cf.latestProcessedBlock->Js.Nullable.fromOption, // this is already optional
        numEventsProcessed: Value(cf.numEventsProcessed),
        poweredByHyperSync: (cf.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
        numBatchesFetched: cf.numBatchesFetched,
        latestFetchedBlockNumber: latestFetchedBlock.blockNumber,
        timestampCaughtUpToHeadOrEndblock: cf.timestampCaughtUpToHeadOrEndblock->Js.Nullable.fromOption,
      }
      chainMetadata
    })
  //Don't await this set, it can happen in its own time
  throttler->Throttler.schedule(() =>
    Db.sql->DbFunctions.ChainMetadata.batchSetChainMetadataRow(~chainMetadataArray)
  )
}

/**
Takes in a chain manager and sets all chains timestamp caught up to head
when valid state lines up and returns an updated chain manager
*/
let checkAndSetSyncedChains = (
  ~nextQueueItemIsKnownNone=false,
  ~shouldSetPrometheusSynced=true,
  chainManager: ChainManager.t,
) => {
  let nextQueueItemIsNone = nextQueueItemIsKnownNone || chainManager->ChainManager.nextItemIsNone

  let allChainsAtHead = chainManager->ChainManager.isFetchingAtHead
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
    ->Array.reduce(true, (accum, cf) =>
      cf.timestampCaughtUpToHeadOrEndblock->Option.isSome && accum
    )

  if allChainsSyncedAtHead && shouldSetPrometheusSynced {
    Prometheus.setAllChainsSyncedToHead()
  }

  {
    ...chainManager,
    chainFetchers,
  }
}

let updateLatestProcessedBlocks = (
  ~state: t,
  ~latestProcessedBlocks: EventProcessing.EventsProcessed.t,
  ~shouldSetPrometheusSynced=true,
) => {
  let chainManager = {
    ...state.chainManager,
    chainFetchers: state.chainManager.chainFetchers->ChainMap.map(cf => {
      let {chainConfig: {chain}, fetchState} = cf
      let {numEventsProcessed, latestProcessedBlock} = latestProcessedBlocks->ChainMap.get(chain)

      let hasNoMoreEventsToProcess = cf->ChainFetcher.hasNoMoreEventsToProcess

      let latestProcessedBlock = if hasNoMoreEventsToProcess {
        FetchState.getLatestFullyFetchedBlock(fetchState).blockNumber->Some
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
    chainManager: chainManager->checkAndSetSyncedChains(~shouldSetPrometheusSynced),
    currentlyProcessingBatch: false,
  }
}

let handlePartitionQueryResponse = (
  state,
  ~chain,
  ~response: Source.blockRangeFetchResponse,
  ~query: FetchState.query,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let {
    parsedQueueItems,
    latestFetchedBlockNumber,
    stats,
    currentBlockHeight,
    reorgGuard,
    fromBlockQueried,
    latestFetchedBlockTimestamp,
  } = response
  let {lastBlockScannedData} = reorgGuard

  if Env.Benchmark.shouldSaveData {
    switch query.target {
    | Merge(_) => ()
    | Head
    | EndBlock(_) =>
      Prometheus.PartitionBlockFetched.set(
        ~blockNumber=latestFetchedBlockNumber,
        ~partitionId=query.partitionId,
        ~chainId=chain->ChainMap.Chain.toChainId,
      )
    }
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

  switch chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
    ~reorgGuard,
    ~currentBlockHeight,
  ) {
  | Error(reorgDetected) if state.config->Config.shouldRollbackOnReorg => {
      chainFetcher.logger->Logging.childInfo(
        reorgDetected->ReorgDetection.reorgDetectedToLogParams(~shouldRollbackOnReorg=true),
      )
      Prometheus.ReorgCount.increment(~chain)
      Prometheus.ReorgDetectionBlockNumber.set(~blockNumber=reorgDetected.scannedBlock.blockNumber, ~chain)
      (state->incrementId->setRollingBack(chain), [Rollback])
    }
  | reorgResult => {
      let lastBlockScannedHashes = switch reorgResult {
      | Ok(lastBlockScannedHashes) => lastBlockScannedHashes
      | Error(reorgDetected) => {
          chainFetcher.logger->Logging.childInfo(
            reorgDetected->ReorgDetection.reorgDetectedToLogParams(~shouldRollbackOnReorg=false),
          )
          Prometheus.ReorgCount.increment(~chain)
          Prometheus.ReorgDetectionBlockNumber.set(
            ~blockNumber=reorgDetected.scannedBlock.blockNumber,
            ~chain,
          )
          ReorgDetection.LastBlockScannedHashes.empty(
            ~confirmedBlockThreshold=chainFetcher.chainConfig.confirmedBlockThreshold,
          )
        }
      }
      let updatedChainFetcher =
        chainFetcher
        ->ChainFetcher.handleQueryResult(
          ~query,
          ~currentBlockHeight,
          ~latestFetchedBlockTimestamp,
          ~latestFetchedBlockNumber,
          ~fetchedEvents=parsedQueueItems,
        )
        ->Utils.unwrapResultExn
        ->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)

      let hasNoMoreEventsToProcess = updatedChainFetcher->ChainFetcher.hasNoMoreEventsToProcess

      let latestProcessedBlock = if hasNoMoreEventsToProcess {
        FetchState.getLatestFullyFetchedBlock(updatedChainFetcher.fetchState).blockNumber->Some
      } else {
        updatedChainFetcher.latestProcessedBlock
      }

      let updatedChainFetcher = {
        ...updatedChainFetcher,
        latestProcessedBlock,
        lastBlockScannedHashes,
        numBatchesFetched: updatedChainFetcher.numBatchesFetched + 1,
      }

      let wasFetchingAtHead = ChainFetcher.isFetchingAtHead(chainFetcher)
      let isCurrentlyFetchingAtHead = ChainFetcher.isFetchingAtHead(updatedChainFetcher)

      if !wasFetchingAtHead && isCurrentlyFetchingAtHead {
        updatedChainFetcher.logger->Logging.childInfo("All events have been fetched")
      }

      let updateEndOfBlockRangeScannedDataArr =
        //Only update endOfBlockRangeScannedData if rollbacks are enabled
        state.config->Config.shouldRollbackOnReorg
          ? [
              UpdateEndOfBlockRangeScannedData({
                chain,
                blockNumberThreshold: lastBlockScannedData.blockNumber -
                updatedChainFetcher.chainConfig.confirmedBlockThreshold,
                nextEndOfBlockRangeScannedData: {
                  chainId: chain->ChainMap.Chain.toChainId,
                  blockNumber: lastBlockScannedData.blockNumber,
                  blockHash: lastBlockScannedData.blockHash,
                },
              }),
            ]
          : []

      let nextState = {
        ...state,
        chainManager: {
          ...state.chainManager,
          chainFetchers: state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher),
        },
      }

      (
        nextState,
        Array.concat(
          updateEndOfBlockRangeScannedDataArr,
          [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch, NextQuery(Chain(chain))],
        ),
      )
    }
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
  | FinishWaitingForNewBlock({chain, currentBlockHeight}) => (
      {
        ...state,
        chainManager: {
          ...state.chainManager,
          chainFetchers: state.chainManager.chainFetchers->ChainMap.update(chain, chainFetcher => {
            chainFetcher->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)
          }),
        },
      },
      [NextQuery(Chain(chain))],
    )
  | PartitionQueryResponse({chain, response, query}) =>
    state->handlePartitionQueryResponse(~chain, ~response, ~query)
  | EventBatchProcessed(latestProcessedBlocks) =>
    let maybePruneEntityHistory =
      state.config->Config.shouldPruneHistory(
        ~isInReorgThreshold=state.chainManager.isInReorgThreshold,
      )
        ? [PruneStaleEntityHistory]
        : []
    (
      updateLatestProcessedBlocks(~state, ~latestProcessedBlocks),
      [UpdateChainMetaDataAndCheckForExit(NoExit), ProcessEventBatch]->Array.concat(
        maybePruneEntityHistory,
      ),
    )
  | SetCurrentlyProcessing(currentlyProcessingBatch) => ({...state, currentlyProcessingBatch}, [])
  | SetIsInReorgThreshold(isInReorgThreshold) =>
    if isInReorgThreshold {
      Logging.info("Reorg threshold reached")
    }
    ({...state, chainManager: {...state.chainManager, isInReorgThreshold}}, [])
  | SetSyncedChains => {
      let shouldExit = EventProcessing.EventsProcessed.allChainsEventsProcessedToEndblock(
        state.chainManager.chainFetchers,
      )
        ? {
            Logging.info("All chains are caught up to the endblock.")
            // Keep the indexer process running in TUI mode
            // so the Dev Console server stays working
            state.shouldUseTui ? NoExit : ExitWithSuccess
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
  | UpdateQueues(fetchStatesMap) =>
    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      {
        ...cf,
        fetchState: ChainMap.get(fetchStatesMap, chain).fetchState,
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

let actionNameSchema = S.union([S.string, S.object(s => s.field("TAG", S.string))])

let invalidatedActionReducer = (state: t, action: action) =>
  switch (state, action) {
  | ({rollbackState: RollingBack(_)}, EventBatchProcessed(_)) =>
    Logging.info("Finished processing batch before rollback, actioning rollback")
    ({...state, currentlyProcessingBatch: false}, [Rollback])
  | (_, ErrorExit(_)) => actionReducer(state, action)
  | _ =>
    Logging.info({
      "msg": "Invalidated action discarded",
      "action": action->S.convertOrThrow(actionNameSchema),
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
          dispatchAction(PartitionQueryResponse({chain, response, query}))
        } catch {
        | exn => dispatchAction(ErrorExit(exn->ErrorHandling.make))
        }
      },
      ~maxPerChainQueueSize=state.maxPerChainQueueSize,
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
      let safeChainIdAndBlockNumberArray =
        state.chainManager->ChainManager.getSafeChainIdAndBlockNumberArray

      if safeChainIdAndBlockNumberArray->Belt.Array.length > 0 {
        let shouldDeepClean = if (
          state.writeThrottlers.deepCleanCount ==
            Env.ThrottleWrites.deepCleanEntityHistoryCycleCount
        ) {
          state.writeThrottlers.deepCleanCount = 0
          true
        } else {
          state.writeThrottlers.deepCleanCount = state.writeThrottlers.deepCleanCount + 1
          false
        }
        let timeRef = Hrtime.makeTimer()
        let _ = await Promise.all(
          Entities.allEntities->Belt.Array.map(entityMod => {
            let module(Entity) = entityMod
            Db.sql->DbFunctions.EntityHistory.pruneStaleEntityHistory(
              ~entityName=Entity.name,
              ~safeChainIdAndBlockNumberArray,
              ~shouldDeepClean,
            )
          }),
        )

        if Env.Benchmark.shouldSaveData {
          let elapsedTimeMillis = Hrtime.timeSince(timeRef)->Hrtime.toMillis->Hrtime.floatFromMillis

          Benchmark.addSummaryData(
            ~group="Other",
            ~label="Prune Stale History Time (ms)",
            ~value=elapsedTimeMillis,
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
      ->Promise.thenResolve(_ => dispatchAction(SuccessExit))
      ->ignore
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
      //Allows us to process events all the way up until we hit the reorg threshold
      //across all chains before starting to capture entity history
      let onlyBelowReorgThreshold = if state.config->Config.shouldRollbackOnReorg {
        state.chainManager.isInReorgThreshold ? false : true
      } else {
        false
      }

      let batch =
        state.chainManager->ChainManager.createBatch(
          ~maxBatchSize=state.maxBatchSize,
          ~onlyBelowReorgThreshold,
        )

      let handleBatch = async (batch: ChainManager.batch) => {
        switch batch {
        | {items: []} => dispatchAction(SetSyncedChains) //Known that there are no items available on the queue so safely call this action
        | {isInReorgThreshold, items, fetchStatesMap, dcsToStoreByChainId} =>
          dispatchAction(SetCurrentlyProcessing(true))
          dispatchAction(UpdateQueues(fetchStatesMap))
          if (
            state.config->Config.shouldRollbackOnReorg &&
            isInReorgThreshold &&
            !state.chainManager.isInReorgThreshold
          ) {
            //On the first time we enter the reorg threshold, copy all entities to entity history
            //And set the isInReorgThreshold isInReorgThreshold state to true
            dispatchAction(SetIsInReorgThreshold(true))
          }

          let isInReorgThreshold = state.chainManager.isInReorgThreshold || isInReorgThreshold

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

          if dcsToStoreByChainId->Utils.Dict.size > 0 {
            let shouldSaveHistory = state.config->Config.shouldSaveHistory(~isInReorgThreshold)
            inMemoryStore->InMemoryStore.setDcsToStore(dcsToStoreByChainId, ~shouldSaveHistory)
          }

          switch await EventProcessing.processEventBatch(
            ~eventBatch=items,
            ~inMemoryStore,
            ~isInReorgThreshold,
            ~latestProcessedBlocks,
            ~loadLayer=state.loadLayer,
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
        }
      }

      switch batch {
      | {isInReorgThreshold: true, items: []} if onlyBelowReorgThreshold =>
        dispatchAction(SetIsInReorgThreshold(true))
        let batch =
          state.chainManager->ChainManager.createBatch(
            ~maxBatchSize=state.maxBatchSize,
            ~onlyBelowReorgThreshold=false,
          )
        await handleBatch(batch)
      | _ => await handleBatch(batch)
      }
    }
  | Rollback =>
    //If it isn't processing a batch currently continue with rollback otherwise wait for current batch to finish processing
    switch state {
    | {currentlyProcessingBatch: false, rollbackState: RollingBack(reorgChain)} =>
      let endTimer = Prometheus.RollbackDuration.startTimer()

      let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(reorgChain)

      let {
        blockNumber: lastKnownValidBlockNumber,
        blockTimestamp: lastKnownValidBlockTimestamp,
      }: ReorgDetection.blockDataWithTimestamp =
        await chainFetcher->getLastKnownValidBlock

      chainFetcher.logger->Logging.childInfo({
        "msg": "Started rollback on reorg",
        "targetBlockNumber": lastKnownValidBlockNumber,
        "targetBlockTimestamp": lastKnownValidBlockTimestamp,
      })
      Prometheus.RollbackTargetBlockNumber.set(~blockNumber=lastKnownValidBlockNumber, ~chain=reorgChain)

      let isUnorderedMultichainMode = state.config.isUnorderedMultichainMode

      let reorgChainId = reorgChain->ChainMap.Chain.toChainId

      //Get the first change event that occurred on each chain after the last known valid block
      //Uses a different method depending on if the reorg chain is ordered or unordered
      let firstChangeEventIdentifierPerChain =
        await Db.sql->DbFunctions.EntityHistory.getFirstChangeEventPerChain(
          isUnorderedMultichainMode
            ? UnorderedMultichain({
                reorgChainId,
                safeBlockNumber: lastKnownValidBlockNumber,
              })
            : OrderedMultichain({
                safeBlockTimestamp: lastKnownValidBlockTimestamp,
                reorgChainId,
                safeBlockNumber: lastKnownValidBlockNumber,
              }),
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
            ~filter=eventItem => {
              //Filter out events that occur passed the block where the query starts but
              //are lower than the timestamp where we rolled back to
              (eventItem.blockNumber, eventItem.logIndex) >=
              (firstChangeEvent.blockNumber, firstChangeEvent.logIndex)
            },
            ~isValid=(~fetchState) => {
              //Remove the event filter once the fetchState has fetched passed the
              //blockNumber of the valid first change event
              let {blockNumber} = FetchState.getLatestFullyFetchedBlock(fetchState)
              blockNumber <= firstChangeEvent.blockNumber
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
        ~isUnorderedMultichainMode,
      )

      let chainManager = {
        ...state.chainManager,
        chainFetchers,
      }

      chainFetcher.logger->Logging.childInfo({
        "msg": "Finished rollback on reorg",
        "entityChanges": {
          "deleted": rollbackResult["deletedEntities"],
          "upserted": rollbackResult["setEntities"],
        },
      })
      endTimer()

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
