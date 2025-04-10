

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
  //Initialized as 0, increments, when rollbacks occur to invalidate
  //responses based on the wrong stateId
  id: int,
}

let make = (~config, ~chainManager, ~loadLayer) => {
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
  writeThrottlers: WriteThrottlers.make(~config),
  loadLayer,
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

type arbitraryEventQueue = array<Internal.eventItem>

type shouldExit = ExitWithSuccess | NoExit
type action =
  | PartitionQueryResponse({
      chain: chain,
      response: Source.blockRangeFetchResponse,
      query: FetchState.query,
    })
  | FinishWaitingForNewBlock({chain: chain, currentBlockHeight: int})
  | EventBatchProcessed(EventProcessing.batchProcessed)
  | DynamicContractPreRegisterProcessed(EventProcessing.batchProcessed)
  | StartIndexingAfterPreRegister
  | SetCurrentlyProcessing(bool)
  | SetIsInReorgThreshold(bool)
  | UpdateQueues(ChainMap.t<ChainManager.fetchStateWithData>, arbitraryEventQueue)
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
  | PreRegisterDynamicContracts
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
        let hasArbQueueEvents =
          chainManager->ChainManager.hasChainItemsOnArbQueue(~chain=cf.chainConfig.chain)
        let hasNoMoreEventsToProcess = cf->ChainFetcher.hasNoMoreEventsToProcess(~hasArbQueueEvents)

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

      let hasArbQueueEvents = state.chainManager->ChainManager.hasChainItemsOnArbQueue(~chain)
      let hasNoMoreEventsToProcess = cf->ChainFetcher.hasNoMoreEventsToProcess(~hasArbQueueEvents)

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
      ~numAddresses=query.contractAddressMapping->ContractAddressingMap.addressCount,
      ~queryName=switch query {
      | {target: Merge(_)} => `Merge Query`
      | {selection: {dependsOnAddresses: false}} => `Wildcard Query`
      | {selection: {dependsOnAddresses: true}} => `Normal Query`
      },
    )
  }

  chainFetcher.logger->Logging.childTrace({
    "msg": "Finished page range",
    "fromBlock": fromBlockQueried,
    "toBlock": latestFetchedBlockNumber,
    "number of logs": parsedQueueItems->Array.length,
    "stats": stats,
  })

  switch chainFetcher.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
    ~reorgGuard,
    ~currentBlockHeight,
  ) {
  | Error(reorgDetected) if state.config->Config.shouldRollbackOnReorg => {
      chainFetcher.logger->Logging.childInfo(
        reorgDetected->ReorgDetection.reorgDetectedToLogParams(~shouldRollbackOnReorg=true),
      )
      Prometheus.incrementReorgsDetected(~chain)
      (state->incrementId->setRollingBack(chain), [Rollback])
    }
  | reorgResult => {
      let lastBlockScannedHashes = switch reorgResult {
      | Ok(lastBlockScannedHashes) => lastBlockScannedHashes
      | Error(reorgDetected) => {
          chainFetcher.logger->Logging.childInfo(
            reorgDetected->ReorgDetection.reorgDetectedToLogParams(~shouldRollbackOnReorg=false),
          )
          Prometheus.incrementReorgsDetected(~chain)
          ReorgDetection.LastBlockScannedHashes.empty(
            ~confirmedBlockThreshold=chainFetcher.chainConfig.confirmedBlockThreshold,
          )
        }
      }
      let updatedChainFetcher =
        chainFetcher
        ->ChainFetcher.setQueryResponse(
          ~query,
          ~currentBlockHeight,
          ~latestFetchedBlockTimestamp,
          ~latestFetchedBlockNumber,
          ~fetchedEvents=parsedQueueItems,
        )
        ->Utils.unwrapResultExn
        ->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)

      let hasArbQueueEvents = state.chainManager->ChainManager.hasChainItemsOnArbQueue(~chain)
      let hasNoMoreEventsToProcess =
        updatedChainFetcher->ChainFetcher.hasNoMoreEventsToProcess(~hasArbQueueEvents)

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

      let processAction =
        updatedChainFetcher->ChainFetcher.isPreRegisteringDynamicContracts
          ? PreRegisterDynamicContracts
          : ProcessEventBatch

      (
        nextState,
        Array.concat(
          updateEndOfBlockRangeScannedDataArr,
          [UpdateChainMetaDataAndCheckForExit(NoExit), processAction, NextQuery(Chain(chain))],
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
  | EventBatchProcessed({
      latestProcessedBlocks,
      dynamicContractRegistrations: Some({dynamicContractsByChain, unprocessedBatch}),
    }) =>
    let updatedArbQueue = Utils.Array.mergeSorted((a, b) => {
      a->EventUtils.getEventComparatorFromQueueItem > b->EventUtils.getEventComparatorFromQueueItem
    }, unprocessedBatch->Array.reverse, state.chainManager.arbitraryEventQueue)

    let maybePruneEntityHistory =
      state.config->Config.shouldPruneHistory(
        ~isInReorgThreshold=state.chainManager.isInReorgThreshold,
      )
        ? [PruneStaleEntityHistory]
        : []

    let nextTasks =
      [
        UpdateChainMetaDataAndCheckForExit(NoExit),
        ProcessEventBatch,
        NextQuery(CheckAllChains),
      ]->Array.concat(maybePruneEntityHistory)

    let updatedChainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((
      chain,
      cf,
    ) => {
      switch dynamicContractsByChain->Utils.Dict.dangerouslyGetNonOption(
        chain->ChainMap.Chain.toString,
      ) {
      | None => cf
      | Some(dcs) => {
          let fetchState =
            cf.fetchState->FetchState.registerDynamicContracts(
              dcs,
              ~currentBlockHeight=cf.currentBlockHeight,
            )

          {
            ...cf,
            fetchState,
            timestampCaughtUpToHeadOrEndblock: fetchState.isFetchingAtHead
              ? cf.timestampCaughtUpToHeadOrEndblock
              : None,
          }
        }
      }
    })

    let updatedChainManager: ChainManager.t = {
      ...state.chainManager,
      chainFetchers: updatedChainFetchers,
      arbitraryEventQueue: updatedArbQueue,
    }

    let nextState = {
      ...state,
      chainManager: updatedChainManager,
    }
    let nextState = updateLatestProcessedBlocks(~state=nextState, ~latestProcessedBlocks)
    // This ONLY updates the metrics - no logic is performed.
    nextState.chainManager.chainFetchers
    ->ChainMap.entries
    ->Array.forEach(((chain, chainFetcher)) => {
      let highestFetchedBlockOnChain = FetchState.getLatestFullyFetchedBlock(
        chainFetcher.fetchState,
      ).blockNumber

      Prometheus.setFetchedUntilHeight(~blockNumber=highestFetchedBlockOnChain, ~chain)
      switch chainFetcher.latestProcessedBlock {
      | Some(blockNumber) => Prometheus.setProcessedUntilHeight(~blockNumber, ~chain)
      | None => ()
      }
    })
    (nextState, nextTasks)

  | EventBatchProcessed({latestProcessedBlocks, dynamicContractRegistrations: None}) =>
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
  | UpdateQueues(fetchStatesMap, arbitraryEventQueue) =>
    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      {
        ...cf,
        fetchState: ChainMap.get(fetchStatesMap, chain).fetchState,
      }
    })

    let chainManager = {
      ...state.chainManager,
      chainFetchers,
      arbitraryEventQueue,
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
  | DynamicContractPreRegisterProcessed({latestProcessedBlocks, dynamicContractRegistrations}) =>
    let state = updateLatestProcessedBlocks(
      ~state,
      ~latestProcessedBlocks,
      ~shouldSetPrometheusSynced=false,
    )

    let state = switch dynamicContractRegistrations {
    | None => state
    | Some({dynamicContractsByChain}) =>
      let updatedChainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((
        chain,
        cf,
      ) => {
        switch dynamicContractsByChain->Utils.Dict.dangerouslyGetNonOption(
          chain->ChainMap.Chain.toString,
        ) {
        | None => cf
        | Some(dcs) => {
            let contractAddressMapping = Js.Dict.empty()

            dcs->Array.forEach(dc =>
              contractAddressMapping->Js.Dict.set(dc.contractAddress->Address.toString, dc)
            )

            let dynamicContractPreRegistration = switch cf.dynamicContractPreRegistration {
            | Some(current) => current->Utils.Dict.merge(contractAddressMapping)
            //Should never be the case while this task is being scheduled
            | None => contractAddressMapping
            }->Some

            {
              ...cf,
              dynamicContractPreRegistration,
            }
          }
        }
      })

      let updatedChainManager = {
        ...state.chainManager,
        chainFetchers: updatedChainFetchers,
      }
      {
        ...state,
        chainManager: updatedChainManager,
      }
    }

    (
      state,
      [
        UpdateChainMetaDataAndCheckForExit(NoExit),
        PreRegisterDynamicContracts,
        NextQuery(CheckAllChains),
      ],
    )
  | StartIndexingAfterPreRegister =>
    let {config, chainManager, loadLayer} = state

    Logging.info("Starting indexing after pre-registration")
    let chainFetchers = chainManager.chainFetchers->ChainMap.map(cf => {
      let {
        chainConfig,
        logger,
        startBlock,
        fetchState: {maxAddrInPartition},
        dynamicContractPreRegistration,
      } = cf

      ChainFetcher.make(
        ~dynamicContracts=dynamicContractPreRegistration->Option.mapWithDefault([], Js.Dict.values),
        ~chainConfig,
        ~lastBlockScannedHashes=ReorgDetection.LastBlockScannedHashes.empty(
          ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
        ),
        ~startBlock,
        ~endBlock=chainConfig.endBlock,
        ~dbFirstEventBlockNumber=None,
        ~latestProcessedBlock=None,
        ~logger,
        ~timestampCaughtUpToHeadOrEndblock=None,
        ~numEventsProcessed=0,
        ~numBatchesFetched=0,
        ~processingFilters=None,
        ~maxAddrInPartition,
        ~dynamicContractPreRegistration=None,
        ~enableRawEvents=config.enableRawEvents,
      )
    })

    let chainManager: ChainManager.t = {
      chainFetchers,
      arbitraryEventQueue: [],
      isInReorgThreshold: false,
      isUnorderedMultichainMode: chainManager.isUnorderedMultichainMode,
    }

    let freshState = make(~config, ~chainManager, ~loadLayer)

    (freshState->incrementId, [NextQuery(CheckAllChains)])
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
  switch (state, action) {
  | ({rollbackState: RollingBack(_)}, EventBatchProcessed(_)) =>
    Logging.info("Finished processing batch before rollback, actioning rollback")
    ({...state, currentlyProcessingBatch: false}, [Rollback])
  | (_, ErrorExit(_)) => actionReducer(state, action)
  | _ =>
    Logging.info("Invalidated action discarded")
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
  | PreRegisterDynamicContracts =>
    let startIndexingAfterPreRegister = async () => {
      //Persisted event sync state needs to reset before starting indexing
      //otherwise crash and restart will have stale sync state from pre-registration
      await DbFunctions.EventSyncState.resetEventSyncState()
      dispatchAction(StartIndexingAfterPreRegister)
    }
    if !state.currentlyProcessingBatch && !isRollingBack(state) {
      switch state.chainManager->ChainManager.createBatch(
        ~maxBatchSize=state.maxBatchSize,
        ~onlyBelowReorgThreshold=true,
      ) {
      | {val: Some({batch, fetchStatesMap, arbitraryEventQueue})} =>
        dispatchAction(SetCurrentlyProcessing(true))
        dispatchAction(UpdateQueues(fetchStatesMap, arbitraryEventQueue))
        let latestProcessedBlocks = EventProcessing.EventsProcessed.makeFromChainManager(
          state.chainManager,
        )

        let checkContractIsRegistered = (
          ~chain,
          ~contractAddress,
          ~contractName: Enums.ContractType.t,
        ) => {
          let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)

          switch chainFetcher.dynamicContractPreRegistration->Option.flatMap(
            Js.Dict.get(_, contractAddress->Address.toString),
          ) {
          | Some({contractType}) =>
            FetchState.warnIfAttemptedAddressRegisterOnDifferentContracts(
              ~contractAddress,
              ~contractName=(contractName :> string),
              ~existingContractName=(contractType :> string),
              ~chainId=chain->ChainMap.Chain.toChainId,
            )
            true
          | None => false
          }
        }

        switch await EventProcessing.getDynamicContractRegistrations(
          ~latestProcessedBlocks,
          ~eventBatch=batch,
          ~checkContractIsRegistered,
          ~config=state.config,
        ) {
        | Ok(batchProcessed) => dispatchAction(DynamicContractPreRegisterProcessed(batchProcessed))
        | Error(errHandler) => dispatchAction(ErrorExit(errHandler))
        | exception exn =>
          //All casese should be handled/caught before this with better user messaging.
          //This is just a safety in case something unexpected happens
          let errHandler =
            exn->ErrorHandling.make(
              ~msg="A top level unexpected error occurred during pre registration of dynamic contracts",
            )
          dispatchAction(ErrorExit(errHandler))
        }
      | {isInReorgThreshold: true, val: None} =>
        //pre registration is done, we've hit the multichain reorg threshold
        //on the last batch and there are no items on the queue
        await startIndexingAfterPreRegister()
      | {val: None} if state.chainManager->ChainManager.isFetchingAtHead =>
        //pre registration is done, there are no items on the queue and we are fetching at head
        //this case is only hit if we are indexing chains with no reorg threshold
        await startIndexingAfterPreRegister()
      | {val: None} if !(state.chainManager->ChainManager.isActivelyIndexing) =>
        //pre registration is done, there are no items on the queue
        //this case is hit when there's a chain with an endBlock
        await startIndexingAfterPreRegister()
      | _ => () //Nothing to process and pre registration is not done
      }
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

      let handleBatch = async (
        batch: ChainManager.isInReorgThresholdRes<option<ChainManager.batchRes>>,
      ) => {
        switch batch {
        | {isInReorgThreshold, val: Some({batch, fetchStatesMap, arbitraryEventQueue})} =>
          dispatchAction(SetCurrentlyProcessing(true))
          dispatchAction(UpdateQueues(fetchStatesMap, arbitraryEventQueue))
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

          // This function is used to ensure that registering an alreday existing contract as a dynamic contract can't cause issues.
          let checkContractIsRegistered = (
            ~chain,
            ~contractAddress,
            ~contractName: Enums.ContractType.t,
          ) => {
            let {fetchState} = fetchStatesMap->ChainMap.get(chain)
            fetchState->FetchState.checkContainsRegisteredContractAddress(
              ~contractAddress,
              ~contractName=(contractName :> string),
              ~chainId=chain->ChainMap.Chain.toChainId,
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
            ~isInReorgThreshold,
            ~checkContractIsRegistered,
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
        | {val: None} => dispatchAction(SetSyncedChains) //Known that there are no items available on the queue so safely call this action
        }
      }

      switch batch {
      | {isInReorgThreshold: true, val: None} if onlyBelowReorgThreshold =>
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
      let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(reorgChain)

      let {
        blockNumber: lastKnownValidBlockNumber,
        blockTimestamp: lastKnownValidBlockTimestamp,
      }: ReorgDetection.blockDataWithTimestamp =
        await chainFetcher->getLastKnownValidBlock

      chainFetcher.logger->Logging.childInfo({
        "msg": "Executing indexer rollback",
        "targetBlockNumber": lastKnownValidBlockNumber,
        "targetBlockTimestamp": lastKnownValidBlockTimestamp,
      })

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
      let inMemoryStore = await IO.RollBack.rollBack(
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

      dispatchAction(SetRollbackState(inMemoryStore, chainManager))

    | _ => Logging.info("Waiting for batch to finish processing before executing rollback") //wait for batch to finish processing
    }
  }
}

let taskReducer = injectedTaskReducer(
  ~waitForNewBlock=SourceManager.waitForNewBlock,
  ~executeQuery=SourceManager.executeQuery,
  ~getLastKnownValidBlock=ChainFetcher.getLastKnownValidBlock(_),
)
