type chain = ChainMap.Chain.t
type rollbackState =
  | NoRollback
  | ReorgDetected({chain: chain, blockNumber: int})
  | FindingReorgDepth
  | FoundReorgDepth({chain: chain, rollbackTargetBlockNumber: int})
  | RollbackReady({eventsProcessedDiffByChain: dict<float>})

module WriteThrottlers = {
  type t = {pruneStaleEntityHistory: Throttler.t}
  let make = (): t => {
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
    {pruneStaleEntityHistory: pruneStaleEntityHistory}
  }
}

type t = {
  ctx: Ctx.t,
  mutable chainManager: ChainManager.t,
  mutable rollbackState: rollbackState,
  indexerStartTime: Date.t,
  writeThrottlers: WriteThrottlers.t,
  loadManager: LoadManager.t,
  keepProcessAlive: bool,
  exitAfterFirstEventBlock: bool,
  // The single fatal-error handler.
  onError: ErrorHandling.t => unit,
  // Fatal user-caused errors (eg a throwing contract register). The default
  // escapes the promise chain and crashes with the original error untouched;
  // the TestIndexer worker relies on the raw error reaching the worker
  // 'error' event instead of a generic exit code.
  onUserError: exn => unit,
  //Initialized as 0, increments, when rollbacks occur to invalidate
  //responses based on the wrong stateId
  mutable id: int,
}

let make = (
  ~ctx: Ctx.t,
  ~chainManager: ChainManager.t,
  ~isDevelopmentMode=false,
  ~shouldUseTui=false,
  ~exitAfterFirstEventBlock=false,
  ~onError: ErrorHandling.t => unit,
  ~onUserError=exn => NodeJs.setImmediate(() => exn->Utils.prettifyExn->throw),
) => {
  {
    ctx,
    chainManager,
    indexerStartTime: Date.make(),
    rollbackState: NoRollback,
    writeThrottlers: WriteThrottlers.make(),
    loadManager: LoadManager.make(),
    keepProcessAlive: isDevelopmentMode || shouldUseTui,
    exitAfterFirstEventBlock,
    onError,
    onUserError,
    id: 0,
  }
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

let unexpectedErrorMsg = "Indexer has failed with an unexpected error"

// Staleness rule: `schedule` guards entry — a scheduled function only starts if
// the id captured at scheduling time still matches. The id can't change while
// code runs synchronously, so a function needs its own `stateId !== state.id`
// check only where it resumes after an await or runs as a source callback.
// Two deliberate exceptions ignore the check: errorExit always runs, and
// rollback owns the id bump that invalidates everything else.
let schedule = (state: t, run: (~stateId: int) => promise<unit>) => {
  let stateId = state.id
  NodeJs.setImmediate(() => {
    if stateId !== state.id {
      Logging.info("Invalidated task discarded")
    } else {
      switch run(~stateId) {
      | exception exn => state.onError(exn->ErrorHandling.make(~msg=unexpectedErrorMsg))
      | promise =>
        promise
        ->Promise.catch(exn => {
          state.onError(exn->ErrorHandling.make(~msg=unexpectedErrorMsg))
          Promise.resolve()
        })
        ->Promise.ignore
      }
    }
  })
}

let stageChainMetadata = (state: t) => {
  let chainsData: dict<InternalTable.Chains.metaFields> = Dict.make()

  state.chainManager.chainFetchers
  ->ChainMap.values
  ->Array.forEach(cf => {
    chainsData->Dict.set(
      cf.chainConfig.id->Int.toString,
      {
        firstEventBlockNumber: cf.fetchState.firstEventBlock->Null.fromOption,
        isHyperSync: (cf.sourceManager->SourceManager.getActiveSource).poweredByHyperSync,
        latestFetchedBlockNumber: cf.fetchState->FetchState.bufferBlockNumber,
        timestampCaughtUpToHeadOrEndblock: cf.timestampCaughtUpToHeadOrEndblock->Null.fromOption,
      },
    )
  })

  // Staged; the cycle folds the stale diff into the next batch write.
  state.ctx.inMemoryStore->InMemoryStore.setChainMeta(chainsData)
}

let enterReorgThreshold = (state: t) => {
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

  state.chainManager = {
    ...state.chainManager,
    chainFetchers,
    isInReorgThreshold: true,
  }
}

let successExit = (state: t, ~stateId) =>
  if stateId === state.id {
    Logging.info("Exiting with success")
    NodeJs.process->NodeJs.exitWithCode(Success)
  }

// The single fatal-error handler. Runs regardless of the captured stateId, so
// a rollback in flight can never swallow an error.
let errorExit = (state: t, errHandler) => state.onError(errHandler)

let rec onQueryResponse = (
  state: t,
  {chain, response} as partitionQueryResponse: partitionQueryResponse,
  ~stateId,
) =>
  if stateId !== state.id {
    ()
  } else {
    let originalChainManager = state.chainManager
    let chainFetcher = originalChainManager.chainFetchers->ChainMap.get(chain)
    let {
      parsedQueueItems,
      latestFetchedBlockNumber,
      stats,
      knownHeight,
      blockHashes,
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
      ~parsingTimeElapsed=stats.parsingTimeElapsed->Option.getOr(0.),
      ~numEvents=parsedQueueItems->Array.length,
      ~blockRangeSize=latestFetchedBlockNumber - fromBlockQueried + 1,
    )

    let (updatedReorgDetection, reorgResult: ReorgDetection.reorgResult) =
      chainFetcher.reorgDetection->ReorgDetection.registerReorgGuard(~blockHashes, ~knownHeight)

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
    | None =>
      state.chainManager = {
        ...originalChainManager,
        chainFetchers: originalChainManager.chainFetchers->ChainMap.set(
          chain,
          {
            ...chainFetcher,
            reorgDetection: updatedReorgDetection,
          },
        ),
      }
      schedule(state, (~stateId) =>
        processPartitionQueryResponse(state, partitionQueryResponse, ~stateId)
      )
    | Some(reorgDetectedBlockNumber) =>
      let restoredChainFetchers = switch state.rollbackState {
      | RollbackReady({eventsProcessedDiffByChain}) =>
        // Restore event counters for ALL chains, not just the reorg chain.
        // The previous rollback subtracted from all chains' counters,
        // but was never committed to DB. So we must undo the subtraction
        // for every chain before the new rollback subtracts again.
        originalChainManager.chainFetchers->ChainMap.mapWithKey((c, chainFetcher) => {
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
        })
      | _ => originalChainManager.chainFetchers
      }
      state.chainManager = {
        ...originalChainManager,
        chainFetchers: restoredChainFetchers->ChainMap.map(chainFetcher => {
          ...chainFetcher,
          // TODO: It's not optimal to abort pending queries for all chains,
          // this is how it always worked, but we should consider a better approach.
          fetchState: chainFetcher.fetchState->FetchState.resetPendingQueries,
        }),
      }
      state.id = state.id + 1
      state.rollbackState = ReorgDetected({
        chain,
        blockNumber: reorgDetectedBlockNumber,
      })
      schedule(state, (~stateId) => rollback(state, ~stateId))
    }
  }

and submitQueryResponse = (
  state: t,
  ~newItems,
  ~newItemsWithDcs,
  ~knownHeight,
  ~latestFetchedBlock,
  ~query,
  ~chain,
  ~stateId,
) =>
  if stateId !== state.id {
    ()
  } else {
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

    state.chainManager = {
      ...state.chainManager,
      chainFetchers: state.chainManager.chainFetchers->ChainMap.set(chain, updatedChainFetcher),
    }

    schedule(state, async (~stateId as _) => stageChainMetadata(state))
    schedule(state, (~stateId) => processEventBatch(state, ~stateId))
    schedule(state, (~stateId) => checkAndFetchForChain(state, chain, ~stateId))
  }

and finishWaitingForNewBlock = (state: t, ~chain, ~knownHeight, ~stateId) =>
  if stateId !== state.id {
    ()
  } else {
    let updatedChainFetchers = state.chainManager.chainFetchers->ChainMap.update(
      chain,
      chainFetcher => {
        let updatedFetchState = chainFetcher.fetchState->FetchState.updateKnownHeight(~knownHeight)
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

    state.chainManager = {
      ...state.chainManager,
      chainFetchers: updatedChainFetchers,
    }

    // Attempt ProcessEventBatch in case if we have block handlers to run
    if shouldEnterReorgThreshold {
      enterReorgThreshold(state)
      schedule(state, (~stateId) => checkAndFetchAllChains(state, ~stateId))
      schedule(state, (~stateId) => processEventBatch(state, ~stateId))
    } else {
      schedule(state, (~stateId) => checkAndFetchForChain(state, chain, ~stateId))
      schedule(state, (~stateId) => processEventBatch(state, ~stateId))
    }
  }

and eventBatchProcessed = (state: t, ~batch: Batch.t, ~stateId) => {
  let inMemoryStore = state.ctx.inMemoryStore

  // Release the processing flag even when the result is discarded below,
  // so a stale batch can never leave processing stuck.
  inMemoryStore.isProcessing = false
  inMemoryStore.processedBatchesCount = inMemoryStore.processedBatchesCount + 1

  if stateId !== state.id {
    // Stale because a rollback bumped the state id. If that rollback is still
    // being prepared, finish it now that the in-flight batch is done; otherwise
    // discard.
    if state->isPreparingRollback {
      Logging.info("Finished processing batch before rollback, actioning rollback")
      state.chainManager = state.chainManager->ChainManager.updateProgressedChains(~batch)
      schedule(state, (~stateId) => rollback(state, ~stateId))
    }
  } else {
    let shouldPruneEntityHistory =
      state.ctx.config->Config.shouldPruneHistory(
        ~isInReorgThreshold=state.chainManager.isInReorgThreshold,
      )

    // Can safely reset rollback state, since overwrite is not possible.
    // If rollback is pending, the EventBatchProcessed is handled by the stale
    // branch above instead.
    state.rollbackState = NoRollback
    state.chainManager = state.chainManager->ChainManager.updateProgressedChains(~batch)

    let allCaughtUp = EventProcessing.allChainsEventsProcessedToEndblock(
      state.chainManager.chainFetchers,
    )
    if allCaughtUp {
      Logging.info("All chains are caught up to end blocks.")
    }

    // Keep the indexer process running when in development mode (for Dev Console)
    // or when TUI is enabled (for display)
    if allCaughtUp && !state.keepProcessAlive {
      // On exit, stop scheduling processEventBatch: the flush is async and would
      // otherwise keep processing further batches while it runs.
      schedule(state, (~stateId) => exitOnCaughtUp(state, ~stateId))
    } else if (
      // In auto-exit mode, error if all chains reached head with no events found
      !allCaughtUp &&
      state.exitAfterFirstEventBlock &&
      state.chainManager.chainFetchers
      ->ChainMap.values
      ->Array.every(cf => cf.isProgressAtHead && cf.fetchState.endBlock->Option.isNone)
    ) {
      errorExit(
        state,
        ErrorHandling.make(
          Utils.Error.make(
            "No events found between startBlock and chain head. Cannot auto-detect endBlock.",
          ),
        ),
      )
    } else {
      schedule(state, async (~stateId as _) => stageChainMetadata(state))
      schedule(state, (~stateId) => processEventBatch(state, ~stateId))
      if shouldPruneEntityHistory {
        schedule(state, (~stateId) => pruneStaleEntityHistory(state, ~stateId))
      }
    }
  }
}

and exitOnCaughtUp = async (state: t, ~stateId) => {
  stageChainMetadata(state)
  await state.ctx.inMemoryStore->InMemoryStore.flush
  successExit(state, ~stateId)
}

and processPartitionQueryResponse = async (
  state: t,
  {chain, response, query}: partitionQueryResponse,
  ~stateId,
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

  let submit = (~newItemsWithDcs) =>
    submitQueryResponse(
      state,
      ~newItems,
      ~newItemsWithDcs,
      ~knownHeight,
      ~latestFetchedBlock={
        blockNumber: latestFetchedBlockNumber,
        blockTimestamp: latestFetchedBlockTimestamp,
      },
      ~chain,
      ~query,
      ~stateId,
    )

  switch itemsWithContractRegister {
  | [] => submit(~newItemsWithDcs=[])
  | _ =>
    // The contract registration is async, so the submit happens on a fresh
    // read of the latest fetch state.
    switch await ChainFetcher.runContractRegistersOrThrow(
      ~itemsWithContractRegister,
      ~config=state.ctx.config,
    ) {
    | exception exn => state.onUserError(exn)
    | newItemsWithDcs => submit(~newItemsWithDcs)
    }
  }
}

and checkAndFetchForChain = async (state: t, chain, ~stateId) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  if !isPreparingRollback(state) {
    let {fetchState} = chainFetcher
    let isRealtime = state.chainManager.isRealtime

    // Only affects the WaitingForNewBlock branch of fetchNext, where
    // there's nothing to fetch. During backfill any such chain is idle.
    let reducedPolling = !isRealtime

    await chainFetcher.sourceManager->SourceManager.fetchNext(
      ~fetchState,
      ~waitForNewBlock=(~knownHeight) =>
        chainFetcher.sourceManager->SourceManager.waitForNewBlock(
          ~knownHeight,
          ~isRealtime,
          ~reducedPolling,
        ),
      ~onNewBlock=(~knownHeight) => finishWaitingForNewBlock(state, ~chain, ~knownHeight, ~stateId),
      ~executeQuery=async query => {
        try {
          let response = await chainFetcher.sourceManager->SourceManager.executeQuery(
            ~query,
            ~knownHeight=fetchState.knownHeight,
            ~isRealtime,
          )
          onQueryResponse(state, {chain, response, query}, ~stateId)
        } catch {
        | exn => errorExit(state, exn->ErrorHandling.make)
        }
      },
      ~stateId,
    )
  }
}

and checkAndFetchAllChains = async (state: t, ~stateId) => {
  //Mapping from the states chainManager so we can construct tests that don't use
  //all chains
  let _ = await state.chainManager.chainFetchers
  ->ChainMap.keys
  ->Array.map(chain => checkAndFetchForChain(state, chain, ~stateId))
  ->Promise.all
}

and pruneStaleEntityHistory = async (state: t, ~stateId as _) => {
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
}

and processEventBatch = async (state: t, ~stateId) => {
  if !state.ctx.inMemoryStore.isProcessing && !isPreparingRollback(state) {
    // The reorg-threshold and queue updates below advance chainManager for the
    // next round, but the current batch is created and processed against the
    // fetchers as they are now.
    let chainManagerBeforeUpdate = state.chainManager

    let isRollbackBatch = switch state.rollbackState {
    | RollbackReady(_) => true
    | _ => false
    }

    let batch =
      chainManagerBeforeUpdate->ChainManager.createBatch(
        ~processedCheckpointId=state.ctx.inMemoryStore.processedCheckpointId,
        ~batchSizeTarget=state.ctx.config.batchSize,
        ~isRollback=isRollbackBatch,
      )

    let progressedChainsById = batch.progressedChainsById

    let isBelowReorgThreshold =
      !chainManagerBeforeUpdate.isInReorgThreshold && state.ctx.config.shouldRollbackOnReorg
    let shouldEnterReorgThreshold =
      isBelowReorgThreshold &&
      chainManagerBeforeUpdate.chainFetchers
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
      enterReorgThreshold(state)
    }

    if progressedChainsById->Utils.Dict.isEmpty {
      if shouldEnterReorgThreshold {
        schedule(state, (~stateId) => checkAndFetchAllChains(state, ~stateId))
      }

      // When resuming from persisted state, all events may already be processed.
      // Log the same completion message and handle exit just like eventBatchProcessed does.
      if (
        EventProcessing.allChainsEventsProcessedToEndblock(chainManagerBeforeUpdate.chainFetchers)
      ) {
        Logging.info("All chains are caught up to end blocks.")
        if !state.keepProcessAlive {
          await exitOnCaughtUp(state, ~stateId)
        }
      }
    } else {
      let inMemoryStore = state.ctx.inMemoryStore
      inMemoryStore.isProcessing = true

      let chainFetchers = state.chainManager.chainFetchers->ChainMap.mapWithKey((chain, cf) => {
        switch progressedChainsById->Utils.Dict.dangerouslyGetByIntNonOption(
          chain->ChainMap.Chain.toChainId,
        ) {
        | Some(chainAfterBatch) => {
            ...cf,
            // The batch was created from pre-threshold fetch states, so blockLag
            // is applied here; enterReorgThreshold already covered the
            // non-progressed fetchers.
            fetchState: shouldEnterReorgThreshold
              ? chainAfterBatch.fetchState->FetchState.updateInternal(
                  ~blockLag=cf.chainConfig.blockLag,
                )
              : chainAfterBatch.fetchState,
          }
        | None => cf
        }
      })
      state.chainManager = {
        ...state.chainManager,
        chainFetchers,
      }
      schedule(state, (~stateId) => checkAndFetchAllChains(state, ~stateId))

      inMemoryStore->InMemoryStore.setBatchDcs(~batch)

      switch await EventProcessing.processEventBatch(
        ~batch,
        ~inMemoryStore,
        ~loadManager=state.loadManager,
        ~ctx=state.ctx,
        ~chainFetchers=chainManagerBeforeUpdate.chainFetchers,
      ) {
      | exception exn =>
        //All casese should be handled/caught before this with better user messaging.
        //This is just a safety in case something unexpected happens
        let errHandler =
          exn->ErrorHandling.make(~msg="A top level unexpected error occurred during processing")
        errorExit(state, errHandler)
      | res =>
        switch res {
        | Ok() => eventBatchProcessed(state, ~batch, ~stateId)
        | Error(errHandler) => errorExit(state, errHandler)
        }
      }
    }
  }
}

and rollback = async (state: t, ~stateId as _) => {
  //If it isn't processing a batch currently continue with rollback otherwise wait for current batch to finish processing
  switch state.rollbackState {
  | NoRollback | RollbackReady(_) =>
    JsError.throwWithMessage("Internal error: Rollback initiated with invalid state")
  | ReorgDetected({chain, blockNumber: reorgBlockNumber}) =>
    let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)

    state.rollbackState = FindingReorgDepth
    let rollbackTargetBlockNumber = await chainFetcher->ChainFetcher.getLastKnownValidBlock(
      ~reorgBlockNumber,
      ~isRealtime=state.chainManager.isRealtime,
    )

    chainFetcher.sourceManager->SourceManager.onReorg(
      ~rollbackTargetBlock=rollbackTargetBlockNumber,
    )

    state.rollbackState = FoundReorgDepth({chain, rollbackTargetBlockNumber})
    schedule(state, (~stateId) => rollback(state, ~stateId))
  // We can come to this case when event batch finished processing
  // while we are still finding the reorg depth
  // Do nothing here, just wait for reorg depth to be found
  | FindingReorgDepth => ()
  | FoundReorgDepth(_) if state.ctx.inMemoryStore.isProcessing =>
    Logging.info("Waiting for batch to finish processing before executing rollback")
  | FoundReorgDepth({chain: reorgChain, rollbackTargetBlockNumber}) =>
    await executeRollback(state, ~reorgChain, ~rollbackTargetBlockNumber)
  }
}

and executeRollback = async (state: t, ~reorgChain, ~rollbackTargetBlockNumber) => {
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

  // Finish pending batch writes first: the target checkpoint, the progress
  // diff and the rollback diff below must all be computed from the same db
  // state. Otherwise an in-flight batch lands after the progress reads and
  // its entity changes get reverted without the chain progress being
  // rolled back, so the events are never reprocessed.
  await state.ctx.inMemoryStore->InMemoryStore.flush

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
      let fetchState = cf.fetchState->FetchState.rollback(~targetBlockNumber=newProgressBlockNumber)
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
          committedProgressBlockNumber: Pervasives.min(
            cf.committedProgressBlockNumber,
            rollbackTargetBlockNumber,
          ),
        }
      } else {
        cf
      }
    }
  })

  let diff = await state.ctx.inMemoryStore->InMemoryStore.prepareRollbackDiff(
    ~persistence=state.ctx.persistence,
    ~rollbackTargetCheckpointId,
    ~rollbackDiffCheckpointId=state.ctx.inMemoryStore.committedCheckpointId->BigInt.add(1n),
    ~progressBlockNumberByChainId=newProgressBlockNumberPerChain,
  )

  let chainManager = {
    ...state.chainManager,
    chainFetchers,
  }

  logger->Logging.childTrace({
    "msg": "Finished rollback on reorg",
    "entityChanges": {
      "deleted": diff["deletedEntities"],
      "upserted": diff["setEntities"],
    },
    "rollbackedEvents": rollbackedProcessedEvents.contents,
    "beforeCheckpointId": state.ctx.inMemoryStore.committedCheckpointId,
    "targetCheckpointId": rollbackTargetCheckpointId,
  })
  Prometheus.RollbackSuccess.increment(
    ~timeSeconds=Hrtime.timeSince(startTime)->Hrtime.toSecondsFloat,
    ~rollbackedProcessedEvents=rollbackedProcessedEvents.contents,
  )

  state.rollbackState = RollbackReady({eventsProcessedDiffByChain: eventsProcessedDiffByChain})
  state.chainManager = chainManager
  schedule(state, (~stateId) => checkAndFetchAllChains(state, ~stateId))
  schedule(state, (~stateId) => processEventBatch(state, ~stateId))
}

// Kick off the indexer loop. The processEventBatch schedule shouldn't be
// necessary, but is added for safety; it returns immediately doing nothing
// when there are no events on the queues.
let start = (state: t) => {
  schedule(state, (~stateId) => checkAndFetchAllChains(state, ~stateId))
  schedule(state, (~stateId) => processEventBatch(state, ~stateId))
}
