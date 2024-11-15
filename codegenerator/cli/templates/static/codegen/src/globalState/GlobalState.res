open Belt

type chain = ChainMap.Chain.t
type rollbackState = NoRollback | RollingBack(chain) | RollbackInMemStore(InMemoryStore.t)

module WriteThrottlers = {
  type t = {chainMetaData: Throttler.t, pruneStaleData: ChainMap.t<Throttler.t>}
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
    let pruneStaleData = config.chainMap->ChainMap.map(cfg => {
      let intervalMillis = Env.ThrottleWrites.pruneStaleDataIntervalMillis
      let logger = Logging.createChild(
        ~params={
          "context": "Throttler for pruning stale endblock and entity history data",
          "intervalMillis": intervalMillis,
          "chain": cfg.chain,
        },
      )
      Throttler.make(~intervalMillis, ~logger)
    })
    {chainMetaData, pruneStaleData}
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

type arbitraryEventQueue = array<Types.eventBatchQueueItem>

type shouldExit = ExitWithSuccess | NoExit
type action =
  | BlockRangeResponse(chain, ChainWorker.blockRangeFetchResponse)
  | SetFetchStateCurrentBlockHeight(chain, int)
  | EventBatchProcessed(EventProcessing.batchProcessed)
  | DynamicContractPreRegisterProcessed(EventProcessing.batchProcessed)
  | StartIndexingAfterPreRegister
  | SetCurrentlyProcessing(bool)
  | SetIsInReorgThreshold(bool)
  | SetCurrentlyFetchingBatch(chain, PartitionedFetchState.partitionIndexSet)
  | SetFetchState(chain, PartitionedFetchState.t)
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
      blockTimestampThreshold: int,
      nextEndOfBlockRangeScannedData: DbFunctions.EndOfBlockRangeScannedData.endOfBlockRangeScannedData,
    })
  | ProcessEventBatch
  | PreRegisterDynamicContracts
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

let updateChainMetadataTable = async (cm: ChainManager.t, ~throttler: Throttler.t) => {
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
        firstEventBlockNumber: cf->ChainFetcher.getFirstEventBlockNumber,
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
  throttler->Throttler.schedule(() =>
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

  if allChainsSyncedAtHead {
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
) => {
  let chainManager = {
    ...state.chainManager,
    chainFetchers: state.chainManager.chainFetchers->ChainMap.map(cf => {
      let {chainConfig: {chain}, fetchState} = cf
      let {numEventsProcessed, latestProcessedBlock} = latestProcessedBlocks->ChainMap.get(chain)

      let hasArbQueueEvents = state.chainManager->ChainManager.hasChainItemsOnArbQueue(~chain)
      let hasNoMoreEventsToProcess = cf->ChainFetcher.hasNoMoreEventsToProcess(~hasArbQueueEvents)

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

  if Env.saveBenchmarkData {
    Benchmark.addBlockRangeFetched(
      ~totalTimeElapsed=stats.totalTimeElapsed,
      ~parsingTimeElapsed=stats.parsingTimeElapsed->Belt.Option.getWithDefault(0),
      ~pageFetchTime=stats.pageFetchTime->Belt.Option.getWithDefault(0),
      ~chainId=chainFetcher.chainConfig.chain->ChainMap.Chain.toChainId,
      ~fromBlock=fromBlockQueried,
      ~toBlock=heighestQueriedBlockNumber,
      ~fetchStateRegisterId,
      ~numEvents=parsedQueueItems->Array.length,
      ~partitionId,
    )
  }

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
        ~fetchedEvents=parsedQueueItems,
        ~id={fetchStateId: fetchStateRegisterId, partitionId},
      )
      ->Utils.unwrapResultExn
      ->updateChainFetcherCurrentBlockHeight(~currentBlockHeight)

    let hasArbQueueEvents = state.chainManager->ChainManager.hasChainItemsOnArbQueue(~chain)
    let hasNoMoreEventsToProcess =
      chainFetcher->ChainFetcher.hasNoMoreEventsToProcess(~hasArbQueueEvents)

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

    let partitionsCurrentlyFetching =
      chainFetcher.partitionsCurrentlyFetching->Set.Int.remove(partitionId)

    let updatedChainFetcher = {
      ...chainFetcher,
      partitionsCurrentlyFetching,
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
  } else {
    chainFetcher.logger->Logging.childWarn("Reorg detected, rolling back")
    Prometheus.incrementReorgsDetected(~chain)
    let partitionsCurrentlyFetching =
      chainFetcher.partitionsCurrentlyFetching->Set.Int.remove(partitionId)
    let chainFetcher = {
      ...chainFetcher,
      partitionsCurrentlyFetching,
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
      dynamicContractRegistrations: Some({registrations, unprocessedBatch}),
    }) =>
    let updatedArbQueue = Utils.Array.mergeSorted((a, b) => {
      a->EventUtils.getEventComparatorFromQueueItem > b->EventUtils.getEventComparatorFromQueueItem
    }, unprocessedBatch->Array.reverse, state.chainManager.arbitraryEventQueue)

    let nextTasks = [
      UpdateChainMetaDataAndCheckForExit(NoExit),
      ProcessEventBatch,
      NextQuery(CheckAllChains),
    ]

    let nextState = registrations->Array.reduce(state, (state, registration) => {
      let {registeringEventChain, dynamicContracts} = registration

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
        let {registeringEventBlockNumber} = contract
        let isContractWithinSyncedRanged =
          (currentChainFetcher.currentBlockHeight->Int.toFloat -.
            registeringEventBlockNumber->Int.toFloat) /.
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
          registration,
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
        arbitraryEventQueue: updatedArbQueue,
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
  | SetIsInReorgThreshold(isInReorgThreshold) =>
    if isInReorgThreshold {
      Logging.info("Reorg threshold reached")
    }
    ({...state, chainManager: {...state.chainManager, isInReorgThreshold}}, [])
  | SetCurrentlyFetchingBatch(chain, newPartitionsCurrentlyFetching) =>
    updateChainFetcher(currentChainFetcher => {
      ...currentChainFetcher,
      partitionsCurrentlyFetching: Set.Int.union(
        currentChainFetcher.partitionsCurrentlyFetching,
        newPartitionsCurrentlyFetching,
      ),
    }, ~chain, ~state)
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
  | UpdateQueues(fetchStatesMap, arbitraryEventQueue) =>
    let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
      {
        ...cf,
        fetchState: ChainMap.get(fetchStatesMap, chain).partitionedFetchState,
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
    let state = updateLatestProcessedBlocks(~state, ~latestProcessedBlocks)

    let state = switch dynamicContractRegistrations {
    | None => state
    | Some({registrations}) =>
      //Create an empty map for mutating the contractAddress mapping
      let tempChainMap: ChainMap.t<ChainFetcher.addressToDynContractLookup> =
        state.chainManager.chainFetchers->ChainMap.map(_ => Js.Dict.empty())

      registrations->Array.forEach(({dynamicContracts}) =>
        dynamicContracts->Array.forEach(dynamicContract => {
          let chain = ChainMap.Chain.makeUnsafe(~chainId=dynamicContract.chainId)
          let contractAddressMapping = tempChainMap->ChainMap.get(chain)
          contractAddressMapping->Js.Dict.set(
            dynamicContract.contractAddress->Address.toString,
            dynamicContract,
          )
        })
      )

      let updatedChainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((
        chain,
        cf,
      ) => {
        let dynamicContractPreRegistration = switch cf.dynamicContractPreRegistration {
        | Some(current) => current->Utils.Dict.merge(tempChainMap->ChainMap.get(chain))
        //Should never be the case while this task is being scheduled
        | None => tempChainMap->ChainMap.get(chain)
        }->Some

        {
          ...cf,
          dynamicContractPreRegistration,
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
        fetchState: {startBlock, endBlock, maxAddrInPartition},
        dynamicContractPreRegistration,
      } = cf

      ChainFetcher.make(
        ~dynamicContractRegistrations=dynamicContractPreRegistration->Option.mapWithDefault(
          [],
          Js.Dict.values,
        ),
        ~chainConfig,
        ~lastBlockScannedHashes=ReorgDetection.LastBlockScannedHashes.empty(
          ~confirmedBlockThreshold=chainConfig.confirmedBlockThreshold,
        ),
        ~staticContracts=chainConfig->ChainFetcher.getStaticContracts,
        ~startBlock,
        ~endBlock,
        ~dbFirstEventBlockNumber=None,
        ~latestProcessedBlock=None,
        ~logger,
        ~timestampCaughtUpToHeadOrEndblock=None,
        ~numEventsProcessed=0,
        ~numBatchesFetched=0,
        ~processingFilters=None,
        ~maxAddrInPartition,
        ~dynamicContractPreRegistration=None,
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
    Logging.warn("Finished processing batch before rollback, actioning rollback")
    ({...state, currentlyProcessingBatch: false}, [Rollback])
  | _ =>
    Logging.warn("Invalidated action discarded")
    (state, [])
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
  ~isPreRegisteringDynamicContracts,
) => {
  let module(ChainWorker: ChainWorker.S) = chainWorker

  let logger = Logging.createChildFrom(
    ~logger,
    ~params={
      "chainId": chain->ChainMap.Chain.toChainId,
      "logType": "Block Range Query",
      "workerType": ChainWorker.name,
    },
  )
  let logger = query->FetchState.getQueryLogger(~logger)
  ChainWorker.fetchBlockRange(
    ~query,
    ~logger,
    ~currentBlockHeight,
    ~setCurrentBlockHeight,
    ~isPreRegisteringDynamicContracts,
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
) => async chain => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let {chainConfig: {chainWorker}, logger, currentBlockHeight} = chainFetcher

  if !isRollingBack(state) {
    let (nextQuery, nextStateIfChangeRequired) =
      chainFetcher->ChainFetcher.getNextQuery(~maxPerChainQueueSize=state.maxPerChainQueueSize)

    switch nextStateIfChangeRequired {
    | Some(nextFetchState) => dispatchAction(SetFetchState(chain, nextFetchState))
    | None => ()
    }

    let setCurrentBlockHeight = currentBlockHeight =>
      dispatchAction(SetFetchStateCurrentBlockHeight(chain, currentBlockHeight))

    switch nextQuery {
    | WaitForNewBlock =>
      await waitForNewBlock(~logger, ~chainWorker, ~currentBlockHeight, ~setCurrentBlockHeight)
    | NextQuery(queries) =>
      let newPartitionsCurrentlyFetching =
        queries->Array.map(query => query.partitionId)->Set.Int.fromArray
      dispatchAction(SetCurrentlyFetchingBatch(chain, newPartitionsCurrentlyFetching))
      let isPreRegisteringDynamicContracts =
        state.chainManager->ChainManager.isPreRegisteringDynamicContracts
      let _ =
        await queries
        ->Array.map(query =>
          executeNextQuery(
            ~logger,
            ~chainWorker,
            ~currentBlockHeight,
            ~setCurrentBlockHeight,
            ~chain,
            ~query,
            ~dispatchAction,
            ~isPreRegisteringDynamicContracts,
          )
        )
        ->Promise.all
    }
  }
}

let injectedTaskReducer = (
  //Used for dependency injection for tests
  ~waitForNewBlock,
  ~executeNextQuery,
  ~rollbackLastBlockHashesToReorgLocation,
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
      blockTimestampThreshold,
      nextEndOfBlockRangeScannedData,
    }) =>
    let timeRef = Hrtime.makeTimer()
    await DbFunctions.sql->DbFunctions.EndOfBlockRangeScannedData.setEndOfBlockRangeScannedData(
      nextEndOfBlockRangeScannedData,
    )

    if Env.saveBenchmarkData {
      let elapsedTimeMillis = Hrtime.timeSince(timeRef)->Hrtime.toMillis->Hrtime.intFromMillis
      Benchmark.addSummaryData(
        ~group="Other",
        ~label=`Chain ${chain->ChainMap.Chain.toString} UpdateEndOfBlockRangeScannedData (ms)`,
        ~value=elapsedTimeMillis->Belt.Int.toFloat,
      )
    }

    //These prune functions can be scheduled and throttled if a more recent prune function gets called
    //before the current one is executed
    let runPruneFunctions = async () => {
      let timeRef = Hrtime.makeTimer()
      await DbFunctions.sql->DbFunctions.EndOfBlockRangeScannedData.deleteStaleEndOfBlockRangeScannedDataForChain(
        ~chainId=chain->ChainMap.Chain.toChainId,
        ~blockTimestampThreshold,
        ~blockNumberThreshold,
      )

      if Env.saveBenchmarkData {
        let elapsedTimeMillis = Hrtime.timeSince(timeRef)->Hrtime.toMillis->Hrtime.intFromMillis
        Benchmark.addSummaryData(
          ~group="Other",
          ~label=`Chain ${chain->ChainMap.Chain.toString} PruneStaleData (ms)`,
          ~value=elapsedTimeMillis->Belt.Int.toFloat,
        )
      }
    }

    let throttler = state.writeThrottlers.pruneStaleData->ChainMap.get(chain)
    throttler->Throttler.schedule(runPruneFunctions)

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
  | PreRegisterDynamicContracts =>
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

          chainFetcher.dynamicContractPreRegistration
          ->Option.flatMap(Js.Dict.get(_, contractAddress->Address.toString))
          ->Option.mapWithDefault(false, ({contractType}) => contractType == contractName)
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
        dispatchAction(StartIndexingAfterPreRegister)
      | {val: None} if state.chainManager->ChainManager.isFetchingAtHead =>
        //pre registration is done, there are no items on the queue and we are fetching at head
        //this case is only hit if we are indexing chains with no reorg threshold
        dispatchAction(StartIndexingAfterPreRegister)
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
      switch state.chainManager->ChainManager.createBatch(
        ~maxBatchSize=state.maxBatchSize,
        ~onlyBelowReorgThreshold,
      ) {
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
          let {partitionedFetchState} = fetchStatesMap->ChainMap.get(chain)
          partitionedFetchState->PartitionedFetchState.checkContainsRegisteredContractAddress(
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
          ~isInReorgThreshold,
          ~checkContractIsRegistered,
          ~latestProcessedBlocks,
          ~loadLayer=state.loadLayer,
          ~config=state.config,
          ~safeChainIdAndBlockNumberArray=state.chainManager->ChainManager.getSafeChainIdAndBlockNumberArray,
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
      | {val: None} => dispatchAction(SetSyncedChains) //Known that there are no items available on the queue so safely call this action
      }
    }
  | Rollback =>
    //If it isn't processing a batch currently continue with rollback otherwise wait for current batch to finish processing
    switch state {
    | {currentlyProcessingBatch: false, rollbackState: RollingBack(reorgChain)} =>
      Logging.warn("Executing rollback")

      let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(reorgChain)

      //Rollback the lastBlockScannedHashes to a point before blockhashes diverged
      let reorgChainRolledBackLastBlockData =
        await chainFetcher->rollbackLastBlockHashesToReorgLocation

      //Get the last known valid block that was scanned on the reorg chain
      let {blockNumber: lastKnownValidBlockNumber, blockTimestamp: lastKnownValidBlockTimestamp} =
        reorgChainRolledBackLastBlockData->ChainFetcher.getLastScannedBlockData

      let isUnorderedMultichainMode = state.config.isUnorderedMultichainMode

      let reorgChainId = reorgChain->ChainMap.Chain.toChainId

      //Get the first change event that occurred on each chain after the last known valid block
      //Uses a different method depending on if the reorg chain is ordered or unordered
      let firstChangeEventIdentifierPerChain =
        await DbFunctions.sql->DbFunctions.EntityHistory.getFirstChangeEventPerChain(
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
          //There was a change on the given chain after the reorged chain,
          // rollback the lastBlockScannedHashes to before the first change produced by the given chain
          let rolledBackLastBlockData =
            cf.lastBlockScannedHashes->ReorgDetection.LastBlockScannedHashes.rollBackToBlockNumberLt(
              ~blockNumber=firstChangeEvent.blockNumber,
            )

          let fetchState =
            cf.fetchState->PartitionedFetchState.rollback(
              ~lastScannedBlock=rolledBackLastBlockData->ChainFetcher.getLastScannedBlockData,
              ~firstChangeEvent,
            )

          let rolledBackCf = {
            ...cf,
            lastBlockScannedHashes: rolledBackLastBlockData,
            fetchState,
          }
          //On other chains, filter out evennts based on the first change present on the chain after the reorg
          rolledBackCf->ChainFetcher.addProcessingFilter(
            ~filter=eventBatchQueueItem => {
              //Filter out events that occur passed the block where the query starts but
              //are lower than the timestamp where we rolled back to
              (eventBatchQueueItem.blockNumber, eventBatchQueueItem.logIndex) >=
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

      let reorgChainLastBlockScannedData = {
        let reorgChainFetcher = chainFetchers->ChainMap.get(reorgChain)
        reorgChainFetcher.lastBlockScannedHashes->ChainFetcher.getLastScannedBlockData
      }

      //Construct a rolledback in Memory store
      let inMemoryStore = await IO.RollBack.rollBack(
        ~chainId=reorgChain->ChainMap.Chain.toChainId,
        ~blockTimestamp=reorgChainLastBlockScannedData.blockTimestamp,
        ~blockNumber=reorgChainLastBlockScannedData.blockNumber,
        ~logIndex=0,
        ~isUnorderedMultichainMode,
      )

      let chainManager = {
        ...state.chainManager,
        chainFetchers,
      }

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
