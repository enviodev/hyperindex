type chain = ChainMap.Chain.t
type rollbackState =
  | NoRollback
  | ReorgDetected({chain: chain, blockNumber: int})
  | FindingReorgDepth
  | FoundReorgDepth({chain: chain, rollbackTargetBlockNumber: int})
  | RollbackReady({eventsProcessedDiffByChain: dict<float>})

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
  ctx: Ctx.t,
  chainManager: ChainManager.t,
  processedBatches: int,
  currentlyProcessingBatch: bool,
  rollbackState: rollbackState,
  indexerStartTime: Date.t,
  writeThrottlers: WriteThrottlers.t,
  loadManager: LoadManager.t,
  keepProcessAlive: bool,
  exitAfterFirstEventBlock: bool,
  //Initialized as 0, increments, when rollbacks occur to invalidate
  //responses based on the wrong stateId
  id: int,
}

let make = (
  ~ctx: Ctx.t,
  ~chainManager: ChainManager.t,
  ~isDevelopmentMode=false,
  ~shouldUseTui=false,
  ~exitAfterFirstEventBlock=false,
) => {
  {
    ctx,
    currentlyProcessingBatch: false,
    processedBatches: 0,
    chainManager,
    indexerStartTime: Date.make(),
    rollbackState: NoRollback,
    writeThrottlers: WriteThrottlers.make(),
    loadManager: LoadManager.make(),
    keepProcessAlive: isDevelopmentMode || shouldUseTui,
    exitAfterFirstEventBlock,
    id: 0,
  }
}

let getId = self => self.id
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

type shouldExit = ExitWithSuccess | ExitWithError(string) | NoExit

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
      knownHeight: int,
      latestFetchedBlock: FetchState.blockNumberAndTimestamp,
      query: FetchState.query,
      chain: chain,
    })
  | FinishWaitingForNewBlock({chain: chain, knownHeight: int})
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
      rollbackDiff: Persistence.rollbackDiff,
      rollbackedChainManager: ChainManager.t,
      eventsProcessedDiffByChain: dict<float>,
    })

type queryChain = CheckAllChains | Chain(chain)
type task =
  | NextQuery(queryChain)
  | ProcessPartitionQueryResponse(partitionQueryResponse)
  | ProcessEventBatch
  | UpdateChainMetaDataAndCheckForExit(shouldExit)
  | Rollback
  | PruneStaleEntityHistory

let updateChainMetadataTable = (
  cm: ChainManager.t,
  ~persistence: Persistence.t,
  ~throttler: Throttler.t,
) => {
  let chainsData: dict<InternalTable.Chains.metaFields> = Dict.make()

  cm.chainFetchers
  ->ChainMap.values
  ->Belt.Array.forEach(cf => {
    chainsData->Dict.set(
      cf.chainConfig.id->Belt.Int.toString,
      {
        firstEventBlockNumber: cf.fetchState.firstEventBlock->Null.fromOption,
        isHyperSync: (cf.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
        latestFetchedBlockNumber: cf.fetchState->FetchState.bufferBlockNumber,
        timestampCaughtUpToHeadOrEndblock: cf.timestampCaughtUpToHeadOrEndblock->Null.fromOption,
      },
    )
  })

  //Don't await this set, it can happen in its own time
  throttler->Throttler.schedule(() =>
    persistence.storage.setChainMeta(chainsData)->Utils.Promise.ignoreValue
  )
}

/**
Takes in a chain manager and sets all chains timestamp caught up to head
when valid state lines up and returns an updated chain manager
*/
let updateProgressedChains = (chainManager: ChainManager.t, ~batch: Batch.t, ~ctx: Ctx.t) => {
  let nextQueueItemIsNone = chainManager->ChainManager.nextItemIsNone

  let allChainsAtHead = chainManager->ChainManager.isProgressAtHead
  //Update the timestampCaughtUpToHeadOrEndblock values
  let allChainsReady = ref(true)
  let chainFetchers = chainManager.chainFetchers->ChainMap.map(prev => {
    let cf = prev
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
            let blockTimestamp = eventItem.event.block->ctx.config.ecosystem.getTimestamp
            let currentTimeMs = Date.now()->Float.toInt
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
          fetchState: switch cf.fetchState.firstEventBlock {
          | Some(_) => cf.fetchState
          | None =>
            switch batch->Batch.findFirstEventBlockNumber(
              ~chainId=chain->ChainMap.Chain.toChainId,
            ) {
            | Some(_) as firstEventBlock => {...cf.fetchState, firstEventBlock}
            | None => cf.fetchState
            }
          },
          committedProgressBlockNumber: chainAfterBatch.progressBlockNumber,
          numEventsProcessed: chainAfterBatch.totalEventsProcessed,
          isProgressAtHead: cf.isProgressAtHead || chainAfterBatch.isProgressAtHeadWhenBatchCreated,
          safeCheckpointTracking: switch cf.safeCheckpointTracking {
          | Some(safeCheckpointTracking) =>
            Some(
              safeCheckpointTracking->SafeCheckpointTracking.updateOnNewBatch(
                ~sourceBlockNumber=cf.fetchState.knownHeight,
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
    let cf = if cf->ChainFetcher.hasProcessedToEndblock {
      // in the case this is already set, don't reset and instead propagate the existing value
      let timestampCaughtUpToHeadOrEndblock =
        cf->ChainFetcher.isReady ? cf.timestampCaughtUpToHeadOrEndblock : Date.make()->Some
      {
        ...cf,
        timestampCaughtUpToHeadOrEndblock,
      }
    } else if !(cf->ChainFetcher.isReady) && cf.isProgressAtHead {
      //Only calculate and set timestampCaughtUpToHeadOrEndblock if chain fetcher is at the head and
      //its not already set
      //CASE1
      //All chains are caught up to head chainManager queue returns None
      //Meaning we are busy synchronizing chains at the head
      if nextQueueItemIsNone && allChainsAtHead {
        {
          ...cf,
          timestampCaughtUpToHeadOrEndblock: Date.make()->Some,
        }
      } else {
        //CASE2 -> Only calculate if case1 fails
        //All events have been processed on the chain fetchers queue
        //Other chains may be busy syncing
        let hasNoMoreEventsToProcess = cf->ChainFetcher.hasNoMoreEventsToProcess

        if hasNoMoreEventsToProcess {
          {
            ...cf,
            timestampCaughtUpToHeadOrEndblock: Date.make()->Some,
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

    // Set envio_progress_ready per-chain when it first becomes ready
    if cf->ChainFetcher.isReady {
      if !(prev->ChainFetcher.isReady) {
        Prometheus.ProgressReady.set(~chainId=chain->ChainMap.Chain.toChainId)
      }
    } else {
      allChainsReady := false
    }

    cf
  })

  if allChainsReady.contents {
    Prometheus.ProgressReady.setAllReady()
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
  {chain, response} as partitionQueryResponse: partitionQueryResponse,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  let {
    parsedQueueItems,
    latestFetchedBlockNumber,
    stats,
    knownHeight,
    reorgGuard,
    fromBlockQueried,
  } = response

  if knownHeight > chainFetcher.fetchState.knownHeight {
    Prometheus.SourceHeight.set(
      ~blockNumber=knownHeight,
      ~chainId=chainFetcher.chainConfig.id,
      // The knownHeight from response won't necessarily
      // belong to the currently active source.
      // But for simplicity, assume it does.
      ~sourceName=(chainFetcher.sourceManager->SourceManager.getActiveSource).name,
    )
  }

  Prometheus.FetchingBlockRange.increment(
    ~chainId=chain->ChainMap.Chain.toChainId,
    ~totalTimeElapsed=stats.totalTimeElapsed,
    ~parsingTimeElapsed=stats.parsingTimeElapsed->Belt.Option.getWithDefault(0.),
    ~numEvents=parsedQueueItems->Array.length,
    ~blockRangeSize=latestFetchedBlockNumber - fromBlockQueried + 1,
  )

  let (updatedReorgDetection, reorgResult: ReorgDetection.reorgResult) =
    chainFetcher.reorgDetection->ReorgDetection.registerReorgGuard(~reorgGuard, ~knownHeight)

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
          ~shouldRollbackOnReorg=state.ctx.config.shouldRollbackOnReorg,
        ),
      )
      Prometheus.ReorgCount.increment(~chain)
      Prometheus.ReorgDetectionBlockNumber.set(
        ~blockNumber=reorgDetected.scannedBlock.blockNumber,
        ~chain,
      )
      if state.ctx.config.shouldRollbackOnReorg {
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
          // Restore event counters for ALL chains, not just the reorg chain.
          // The previous rollback subtracted from all chains' counters,
          // but was never committed to DB. So we must undo the subtraction
          // for every chain before the new rollback subtracts again.
          chainFetchers: state.chainManager.chainFetchers->ChainMap.mapWithKey((
            c,
            chainFetcher,
          ) => {
            switch eventsProcessedDiffByChain->Utils.Dict.dangerouslyGetByIntNonOption(
              c->ChainMap.Chain.toChainId,
            ) {
            | Some(eventsProcessedDiff) => {
                ...chainFetcher,
                // Since we detected a reorg, until rollback wasn't completed in the db
                // We return the events processed counter to the pre-rollback value,
                // to decrease it once more for the new rollback.
                numEventsProcessed: chainFetcher.numEventsProcessed +. eventsProcessedDiff,
              }
            | None => chainFetcher
            }
          }),
        }
      | _ => state.chainManager
      }
      (
        {
          ...nextState,
          id: nextState.id + 1,
          chainManager: {
            ...chainManager,
            chainFetchers: chainManager.chainFetchers->ChainMap.map(chainFetcher => {
              ...chainFetcher,
              // TODO: It's not optimal to abort pending queries for all chains,
              // this is how it always worked, but we should consider a better approach.
              fetchState: chainFetcher.fetchState->FetchState.resetPendingQueries,
            }),
          },
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
  ~knownHeight,
  ~latestFetchedBlock,
  ~query,
  ~chain,
) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)

  let updatedChainFetcher =
    chainFetcher->ChainFetcher.handleQueryResult(
      ~query,
      ~latestFetchedBlock,
      ~newItems,
      ~newItemsWithDcs,
      ~knownHeight,
    )

  // In auto-exit mode, set endBlock to the first event's block when events arrive.
  // Also update if a partition returns events at an earlier block than current endBlock.
  let updatedChainFetcher = if state.exitAfterFirstEventBlock && newItems->Array.length > 0 {
    let firstEventBlock = newItems->Array.getUnsafe(0)->Internal.getItemBlockNumber
    switch updatedChainFetcher.fetchState.endBlock {
    | None => {
        ...updatedChainFetcher,
        fetchState: {...updatedChainFetcher.fetchState, endBlock: Some(firstEventBlock)},
      }
    | Some(currentEndBlock) if firstEventBlock < currentEndBlock => {
        ...updatedChainFetcher,
        fetchState: {...updatedChainFetcher.fetchState, endBlock: Some(firstEventBlock)},
      }
    | Some(_) => updatedChainFetcher
    }
  } else {
    updatedChainFetcher
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
    knownHeight,
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
      ~config=state.ctx.config,
    )
  }

  dispatchAction(
    SubmitPartitionQueryResponse({
      newItems,
      newItemsWithDcs,
      knownHeight,
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
        ~blockLag=chainFetcher.chainConfig.blockLag,
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
  | FinishWaitingForNewBlock({chain, knownHeight}) => {
      let updatedChainFetchers = state.chainManager.chainFetchers->ChainMap.update(
        chain,
        chainFetcher => {
          let updatedFetchState =
            chainFetcher.fetchState->FetchState.updateKnownHeight(~knownHeight)
          if updatedFetchState !== chainFetcher.fetchState {
            {
              ...chainFetcher,
              fetchState: updatedFetchState,
            }
          } else {
            chainFetcher
          }
        },
      )

      let isBelowReorgThreshold =
        !state.chainManager.isInReorgThreshold && state.ctx.config.shouldRollbackOnReorg
      let shouldEnterReorgThreshold =
        isBelowReorgThreshold &&
        updatedChainFetchers
        ->ChainMap.values
        ->Array.every(chainFetcher => {
          chainFetcher.fetchState->FetchState.isReadyToEnterReorgThreshold
        })

      let state = {
        ...state,
        chainManager: {
          ...state.chainManager,
          chainFetchers: updatedChainFetchers,
        },
      }

      // Attempt ProcessEventBatch in case if we have block handlers to run
      if shouldEnterReorgThreshold {
        (onEnterReorgThreshold(~state), [NextQuery(CheckAllChains), ProcessEventBatch])
      } else {
        (state, [NextQuery(Chain(chain)), ProcessEventBatch])
      }
    }
  | ValidatePartitionQueryResponse(partitionQueryResponse) =>
    state->validatePartitionQueryResponse(partitionQueryResponse)
  | SubmitPartitionQueryResponse({
      newItems,
      newItemsWithDcs,
      knownHeight,
      latestFetchedBlock,
      query,
      chain,
    }) =>
    state->submitPartitionQueryResponse(
      ~newItems,
      ~newItemsWithDcs,
      ~knownHeight,
      ~latestFetchedBlock,
      ~query,
      ~chain,
    )
  | EventBatchProcessed({batch}) =>
    let maybePruneEntityHistory =
      state.ctx.config->Config.shouldPruneHistory(
        ~isInReorgThreshold=state.chainManager.isInReorgThreshold,
      )
        ? [PruneStaleEntityHistory]
        : []

    let state = {
      ...state,
      // Can safely reset rollback state, since overwrite is not possible.
      // If rollback is pending, the EventBatchProcessed will be handled by the invalid action reducer instead.
      rollbackState: NoRollback,
      chainManager: state.chainManager->updateProgressedChains(~batch, ~ctx=state.ctx),
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
      : if (
          // In auto-exit mode, error if all chains reached head with no events found
          state.exitAfterFirstEventBlock &&
          state.chainManager.chainFetchers
          ->ChainMap.values
          ->Array.every(cf => cf.isProgressAtHead && cf.fetchState.endBlock->Belt.Option.isNone)
        ) {
          ExitWithError(
            "No events found between startBlock and chain head. Cannot auto-detect endBlock.",
          )
        } else {
          NoExit
        }

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
          ? fs->FetchState.updateInternal(~blockLag=cf.chainConfig.blockLag)
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
  | SetRollbackState({rollbackDiff, rollbackedChainManager, eventsProcessedDiffByChain}) =>
    state.ctx.inMemoryStore->InMemoryStore.applyRollbackDiff(~rollbackDiff)
    (
      {
        ...state,
        rollbackState: RollbackReady({
          eventsProcessedDiffByChain: eventsProcessedDiffByChain,
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
        chainManager: state.chainManager->updateProgressedChains(~batch, ~ctx=state.ctx),
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
    let {fetchState} = chainFetcher

    await chainFetcher.sourceManager->SourceManager.fetchNext(
      ~fetchState,
      ~waitForNewBlock=(~knownHeight) =>
        chainFetcher.sourceManager->waitForNewBlock(
          ~knownHeight,
          ~isLive=chainFetcher->ChainFetcher.isReady,
        ),
      ~onNewBlock=(~knownHeight) => dispatchAction(FinishWaitingForNewBlock({chain, knownHeight})),
      ~executeQuery=async query => {
        try {
          let response =
            await chainFetcher.sourceManager->executeQuery(
              ~query,
              ~knownHeight=fetchState.knownHeight,
              ~isLive=chainFetcher->ChainFetcher.isReady,
            )
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
    state->processPartitionQueryResponse(partitionQueryResponse, ~dispatchAction)->Promise.ignore
  | PruneStaleEntityHistory =>
    let runPrune = async () => {
      switch state.chainManager->ChainManager.getSafeCheckpointId {
      | None => ()
      | Some(safeCheckpointId) =>
        await state.ctx.persistence.storage.pruneStaleCheckpoints(~safeCheckpointId)

        for idx in 0 to state.ctx.persistence.allEntities->Array.length - 1 {
          if idx !== 0 {
            // Add some delay between entities
            // To unblock the pg client if it's needed for something else
            await Utils.delay(1000)
          }
          let entityConfig = state.ctx.persistence.allEntities->Array.getUnsafe(idx)
          let timeRef = Hrtime.makeTimer()
          try {
            let () = await state.ctx.persistence.storage.pruneStaleEntityHistory(
              ~entityName=entityConfig.name,
              ~entityIndex=entityConfig.index,
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
            ~timeSeconds=Hrtime.timeSince(timeRef)->Hrtime.toSecondsFloat,
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
      // Flush all pending writes before exiting
      await state.ctx.persistence->Persistence.flushWrites
      updateChainMetadataTable(
        chainManager,
        ~throttler=writeThrottlers.chainMetaData,
        ~persistence=state.ctx.persistence,
      )
      dispatchAction(SuccessExit)
    | ExitWithError(msg) =>
      dispatchAction(ErrorExit(ErrorHandling.make(JsError.throwWithMessage(msg))))
    | NoExit =>
      // Check for background write errors (non-blocking)
      if state.ctx.persistence->Persistence.isWriting {
        state.ctx.persistence
        ->Persistence.awaitCurrentWrite
        ->Promise.catch(exn => {
          dispatchAction(ErrorExit(exn->ErrorHandling.make(~msg="Background write failed")))
          Promise.resolve()
        })
        ->Promise.ignore
      }
      updateChainMetadataTable(
        chainManager,
        ~throttler=writeThrottlers.chainMetaData,
        ~persistence=state.ctx.persistence,
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
      let isRollback = switch state.rollbackState {
      | RollbackReady(_) => true
      | _ => false
      }

      let batch =
        state.chainManager->ChainManager.createBatch(
          ~batchSizeTarget=state.ctx.config.batchSize,
          ~isRollback,
        )

      let progressedChainsById = batch.progressedChainsById

      let isInReorgThreshold = state.chainManager.isInReorgThreshold
      let shouldSaveHistory = state.ctx.config->Config.shouldSaveHistory(~isInReorgThreshold)

      let isBelowReorgThreshold =
        !state.chainManager.isInReorgThreshold && state.ctx.config.shouldRollbackOnReorg
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
          fetchState->FetchState.isReadyToEnterReorgThreshold
        })

      if shouldEnterReorgThreshold {
        dispatchAction(EnterReorgThreshold)
      }

      if progressedChainsById->Utils.Dict.isEmpty {
        // When resuming from persisted state, all events may already be processed.
        // Log the same completion message and handle exit just like EventBatchProcessed does.
        if EventProcessing.allChainsEventsProcessedToEndblock(state.chainManager.chainFetchers) {
          Logging.info("All chains are caught up to end blocks.")
          if !state.keepProcessAlive {
            updateChainMetadataTable(
              state.chainManager,
              ~persistence=state.ctx.persistence,
              ~throttler=state.writeThrottlers.chainMetaData,
            )
            dispatchAction(SuccessExit)
          }
        }
      } else {
        // Dispatch before any await to prevent triggering processing twice
        dispatchAction(StartProcessingBatch)
        dispatchAction(UpdateQueues({progressedChainsById, shouldEnterReorgThreshold}))

        let inMemoryStore = state.ctx.inMemoryStore

        inMemoryStore->InMemoryStore.setBatchDcs(~batch, ~shouldSaveHistory)

        switch await EventProcessing.processEventBatch(
          ~batch,
          ~inMemoryStore,
          ~isInReorgThreshold,
          ~loadManager=state.loadManager,
          ~ctx=state.ctx,
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
          | Ok() =>
            // Queue background write and manage in-memory capacity
            await inMemoryStore->InMemoryStore.prepareForNextBatch(
              ~batch,
              ~config=state.ctx.config,
              ~isInReorgThreshold,
              ~persistence=state.ctx.persistence,
            )
            dispatchAction(EventBatchProcessed({batch: batch}))
          | Error(errHandler) => dispatchAction(ErrorExit(errHandler))
          }
        }
      }
    }
  | Rollback =>
    //If it isn't processing a batch currently continue with rollback otherwise wait for current batch to finish processing
    switch state {
    | {rollbackState: NoRollback | RollbackReady(_)} =>
      JsError.throwWithMessage("Internal error: Rollback initiated with invalid state")
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
      // Rollback only runs after batch processing completes (currentlyProcessingBatch: false),
      // so prepareForNextBatch has already queued the write. We just await its completion
      // to ensure DB state is consistent for rollback queries.
      await state.ctx.persistence->Persistence.flushWrites

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
        switch await state.ctx.persistence.storage.getRollbackTargetCheckpoint(
          ~reorgChainId,
          ~lastKnownValidBlockNumber=rollbackTargetBlockNumber,
        ) {
        | Some(checkpointId) => checkpointId
        | None => 0n
        }
      }

      let eventsProcessedDiffByChain = Dict.make()
      let newProgressBlockNumberPerChain = Dict.make()
      let rollbackedProcessedEvents = ref(0.)

      {
        let rollbackProgressDiff = await state.ctx.persistence.storage.getRollbackProgressDiff(
          ~rollbackTargetCheckpointId,
        )
        for idx in 0 to rollbackProgressDiff->Array.length - 1 {
          let diff = rollbackProgressDiff->Array.getUnsafe(idx)
          eventsProcessedDiffByChain->Utils.Dict.setByInt(
            diff["chain_id"],
            {
              let eventsProcessedDiff =
                Float.fromString(diff["events_processed_diff"])->Option.getOrThrow
              rollbackedProcessedEvents := rollbackedProcessedEvents.contents +. eventsProcessedDiff
              eventsProcessedDiff
            },
          )
          newProgressBlockNumberPerChain->Utils.Dict.setByInt(
            diff["chain_id"],
            if rollbackTargetCheckpointId === 0n && diff["chain_id"] === reorgChainId {
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
            cf.numEventsProcessed -.
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

        | None =>
          // Even without a progress diff entry, the reorg chain must have its
          // reorgDetection and fetchState rolled back. Otherwise the stale block hash
          // stays in dataByBlockNumber and the same reorg is re-detected on the next
          // fetch, causing an infinite reorg→rollback loop.
          if chain == reorgChain {
            {
              ...cf,
              reorgDetection: cf.reorgDetection->ReorgDetection.rollbackToValidBlockNumber(
                ~blockNumber=rollbackTargetBlockNumber,
              ),
              fetchState: cf.fetchState->FetchState.rollback(
                ~targetBlockNumber=rollbackTargetBlockNumber,
              ),
            }
          } else {
            cf
          }
        }
      })

      // Prepare rollback diff data (raw, not yet applied to in-memory store)
      let rollbackDiff =
        await state.ctx.persistence->Persistence.prepareRollbackDiff(
          ~rollbackTargetCheckpointId,
          ~rollbackDiffCheckpointId=state.chainManager.committedCheckpointId->BigInt.add(1n),
        )

      let chainManager = {
        ...state.chainManager,
        chainFetchers,
      }

      logger->Logging.childTrace({
        "msg": "Finished rollback on reorg",
        "entityChanges": rollbackDiff.entityChanges->Array.length,
        "rollbackedEvents": rollbackedProcessedEvents.contents,
        "beforeCheckpointId": state.chainManager.committedCheckpointId,
        "targetCheckpointId": rollbackTargetCheckpointId,
      })
      Prometheus.RollbackSuccess.increment(
        ~timeSeconds=Hrtime.timeSince(startTime)->Hrtime.toSecondsFloat,
        ~rollbackedProcessedEvents=rollbackedProcessedEvents.contents,
      )

      dispatchAction(
        SetRollbackState({
          rollbackDiff,
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
