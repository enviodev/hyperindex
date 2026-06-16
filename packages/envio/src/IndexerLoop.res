// The indexer run loop: the fetch / process / rollback control flow. The state
// record and its transitions live in IndexerState; leaf effects live in their own
// modules (ChainMetadata, PruneStaleHistory, ExitOnCaughtUp). This module mutates
// state only through IndexerState transitions.

type partitionQueryResponse = {
  chain: IndexerState.chain,
  response: Source.blockRangeFetchResponse,
  query: FetchState.query,
}

let unexpectedErrorMsg = "Indexer has failed with an unexpected error"

// Yield to the end of the current tick so fetch responses that resolved this
// tick land before the processing loop builds its first batch (coalescing).
@inline
let yieldTick = () => Promise.make((resolve, _) => NodeJs.setImmediate(() => resolve()))

// Fire-and-forget an async step. Every launchable (the processing loop, fetch,
// rollback) owns a try/catch that routes failures to errorExit, so there's no
// rejection to swallow here.
@inline
let launch = (state: IndexerState.t, work: unit => promise<unit>) =>
  if !state.isStopped {
    work()->Promise.ignore
  }

let rec onQueryResponse = async (
  state: IndexerState.t,
  {chain, response, query}: partitionQueryResponse,
  ~stateId,
) =>
  if state->IndexerState.isStale(~stateId) {
    ()
  } else {
    let originalChainManager = state.chainManager
    let chainFetcher = originalChainManager.chainFetchers->ChainMap.get(chain)
    let {
      parsedQueueItems,
      latestFetchedBlockNumber,
      latestFetchedBlockTimestamp,
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
      let chainManager = {
        ...originalChainManager,
        chainFetchers: restoredChainFetchers->ChainMap.map(chainFetcher => {
          ...chainFetcher,
          // TODO: It's not optimal to abort pending queries for all chains,
          // this is how it always worked, but we should consider a better approach.
          fetchState: chainFetcher.fetchState->FetchState.resetPendingQueries,
        }),
      }
      state->IndexerState.beginReorg(~chain, ~blockNumber=reorgDetectedBlockNumber, ~chainManager)
      // Advances synchronously to FindingReorgDepth, so a concurrent rollback
      // kick (eg from the processing loop quiescing) collapses into this one.
      state->launchRollback
    | None =>
      state->IndexerState.setChainFetcher(
        ~chain,
        {...chainFetcher, reorgDetection: updatedReorgDetection},
      )

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

      // Re-check staleness: contract registration is async, so the chain state
      // may have rolled back by the time we apply the fetched items.
      let proceed = (~newItemsWithDcs) =>
        if !(state->IndexerState.isStale(~stateId)) {
          applyQueryResponse(
            state,
            ~chain,
            ~newItems,
            ~newItemsWithDcs,
            ~knownHeight,
            ~latestFetchedBlock={
              FetchState.blockNumber: latestFetchedBlockNumber,
              blockTimestamp: latestFetchedBlockTimestamp,
            },
            ~query,
          )
          ChainMetadata.stage(state)
          state->launchFetchChain(chain)
          state->launchProcessing
        }

      switch itemsWithContractRegister {
      | [] => proceed(~newItemsWithDcs=[])
      | _ =>
        switch await ChainFetcher.runContractRegistersOrThrow(
          ~itemsWithContractRegister,
          ~config=state.ctx.config,
        ) {
        | exception exn => IndexerState.errorExit(state, exn->ErrorHandling.make)
        | newItemsWithDcs => proceed(~newItemsWithDcs)
        }
      }
    }
  }

and applyQueryResponse = (
  state: IndexerState.t,
  ~chain,
  ~newItems,
  ~newItemsWithDcs,
  ~knownHeight,
  ~latestFetchedBlock,
  ~query,
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

  state->IndexerState.setChainFetcher(~chain, updatedChainFetcher)
}

and finishWaitingForNewBlock = (state: IndexerState.t, ~chain, ~knownHeight, ~stateId) =>
  if state->IndexerState.isStale(~stateId) {
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

    state->IndexerState.setChainFetchers(updatedChainFetchers)

    // Kick processing in case there are block handlers to run.
    if shouldEnterReorgThreshold {
      IndexerState.enterReorgThreshold(state)
      state->launchFetchAllChains
    } else {
      state->launchFetchChain(chain)
    }
    state->launchProcessing
  }

and checkAndFetchForChain = async (state: IndexerState.t, chain, ~stateId) => {
  let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
  if !state.isRollingBack && !state.isStopped {
    let {fetchState} = chainFetcher
    let isRealtime = state.chainManager.isRealtime

    // Only affects the WaitingForNewBlock branch of fetchNext, where
    // there's nothing to fetch. During backfill any such chain is idle.
    let reducedPolling = !isRealtime

    // Owns its error boundary: launch doesn't catch, so any failure here (the
    // query, response handling, or fetchNext itself) must stop the indexer.
    try {
      await chainFetcher.sourceManager->SourceManager.fetchNext(
        ~fetchState,
        ~waitForNewBlock=(~knownHeight) =>
          chainFetcher.sourceManager->SourceManager.waitForNewBlock(
            ~knownHeight,
            ~isRealtime,
            ~reducedPolling,
          ),
        ~onNewBlock=(~knownHeight) =>
          finishWaitingForNewBlock(state, ~chain, ~knownHeight, ~stateId),
        ~executeQuery=async query => {
          // Caught here (not just by the outer try) so the query promise never
          // rejects: fetchNext spins a side-chain off it that would otherwise
          // become an unhandled rejection.
          try {
            let response = await chainFetcher.sourceManager->SourceManager.executeQuery(
              ~query,
              ~knownHeight=fetchState.knownHeight,
              ~isRealtime,
            )
            await onQueryResponse(state, {chain, response, query}, ~stateId)
          } catch {
          | exn => IndexerState.errorExit(state, exn->ErrorHandling.make)
          }
        },
        ~stateId,
      )
    } catch {
    | exn => IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=unexpectedErrorMsg))
    }
  }
}

and checkAndFetchAllChains = async (state: IndexerState.t, ~stateId) => {
  //Mapping from the states chainManager so we can construct tests that don't use
  //all chains
  let _ = await state.chainManager.chainFetchers
  ->ChainMap.keys
  ->Array.map(chain => checkAndFetchForChain(state, chain, ~stateId))
  ->Promise.all
}

// The single processing loop. Runs batches back-to-back while there's work and
// no rollback is pending; exits when idle so producers (fetch, rollback) can
// re-kick it. `inMemoryStore.isProcessing` guarantees one instance.
and startProcessing = async (state: IndexerState.t) => {
  if !(state->IndexerState.isProcessing) && !state.isStopped {
    state->IndexerState.beginProcessing
    // FIXME: Needed only for test determinism. The mocks resolve several fetch
    // responses synchronously in one tick; this yield lets them all land before
    // the first createBatch so they coalesce into one batch (matching the old
    // setImmediate model). In production responses arrive on separate network
    // ticks and never co-arrive, so this never coalesces anything real — remove
    // it later to avoid an unnecessary setImmediate per processing burst.
    await yieldTick()
    let shouldContinue = ref(true)
    while shouldContinue.contents && !state.isStopped {
      switch await processNextBatch(state) {
      | exception exn =>
        IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=unexpectedErrorMsg))
        shouldContinue := false
      | didWork => shouldContinue := didWork
      }
    }
    state->IndexerState.endProcessing

    // A reorg detected mid-batch parks the rollback until the loop is idle.
    // Hand off now that no batch is in flight.
    if state.isRollingBack {
      state->launchRollback
    }
  }
}

and processNextBatch = async (state: IndexerState.t): bool =>
  if state.isRollingBack {
    // Park; the loop exit hands off to rollback.
    false
  } else {
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
      IndexerState.enterReorgThreshold(state)
    }

    if progressedChainsById->Utils.Dict.isEmpty {
      if shouldEnterReorgThreshold {
        state->launchFetchAllChains
      }

      // When resuming from persisted state, all events may already be processed.
      if (
        EventProcessing.allChainsEventsProcessedToEndblock(chainManagerBeforeUpdate.chainFetchers)
      ) {
        Logging.info("All chains are caught up to end blocks.")
        if !state.keepProcessAlive {
          await ExitOnCaughtUp.run(state)
        }
      }
      false
    } else {
      let inMemoryStore = state.ctx.inMemoryStore

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
      state->IndexerState.setChainFetchers(chainFetchers)
      // Kick the next fetch round before awaiting the batch. A response that
      // lands mid-batch commits only fetch-frontier fields (buffer, knownHeight)
      // via setChainFetcher(s), while applyBatchProgress below commits only
      // progress fields, so the two concurrent writes are disjoint and neither
      // clobbers the other.
      state->launchFetchAllChains

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
        IndexerState.errorExit(
          state,
          exn->ErrorHandling.make(~msg="A top level unexpected error occurred during processing"),
        )
        false
      | Error(errHandler) =>
        IndexerState.errorExit(state, errHandler)
        false
      | Ok() =>
        state->IndexerState.recordProcessedBatch

        if state.isRollingBack {
          // A reorg landed while this batch was processing. Apply its progress so
          // the rollback diff is computed against up-to-date chain progress, but
          // don't reset rollback state or evaluate exit. The loop exit hands off
          // to rollback.
          state->IndexerState.applyBatchProgress(~batch)
          false
        } else {
          // Can safely reset rollback state, since overwrite is not possible.
          state->IndexerState.clearRollback
          state->IndexerState.applyBatchProgress(~batch)

          if !chainManagerBeforeUpdate.isRealtime && state.chainManager.isRealtime {
            // Catching up just flipped the chain to realtime, which changes the
            // active source for waitForNewBlock (eg sync -> live). The waiter that
            // parked during backfill is bound to the old source; bump the epoch to
            // invalidate it and kick a fresh fetch that parks on the realtime source.
            state->IndexerState.invalidateInflight
            state->launchFetchAllChains
          }

          let allCaughtUp = EventProcessing.allChainsEventsProcessedToEndblock(
            state.chainManager.chainFetchers,
          )
          if allCaughtUp {
            Logging.info("All chains are caught up to end blocks.")
          }

          if allCaughtUp && !state.keepProcessAlive {
            await ExitOnCaughtUp.run(state)
            false
          } else if (
            // In auto-exit mode, error if all chains reached head with no events found
            !allCaughtUp &&
            state.exitAfterFirstEventBlock &&
            state.chainManager.chainFetchers
            ->ChainMap.values
            ->Array.every(cf => cf.isProgressAtHead && cf.fetchState.endBlock->Option.isNone)
          ) {
            IndexerState.errorExit(
              state,
              ErrorHandling.make(
                Utils.Error.make(
                  "No events found between startBlock and chain head. Cannot auto-detect endBlock.",
                ),
              ),
            )
            false
          } else {
            ChainMetadata.stage(state)
            if (
              state.ctx.config->Config.shouldPruneHistory(
                ~isInReorgThreshold=state.chainManager.isInReorgThreshold,
              )
            ) {
              state->PruneStaleHistory.schedule
            }

            // Keep looping unless we're staying alive while fully caught up.
            !(allCaughtUp && state.keepProcessAlive)
          }
        }
      }
    }
  }

and rollback = async (state: IndexerState.t) =>
  // Owns its error boundary: launch doesn't catch, so a failure mid-rollback
  // must stop the indexer.
  try {
    switch state.rollbackState {
    | NoRollback | RollbackReady(_) =>
      JsError.throwWithMessage("Internal error: Rollback initiated with invalid state")
    | ReorgDetected({chain, blockNumber: reorgBlockNumber}) =>
      let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)

      state->IndexerState.enterFindingReorgDepth
      let rollbackTargetBlockNumber = await chainFetcher->ChainFetcher.getLastKnownValidBlock(
        ~reorgBlockNumber,
        ~isRealtime=state.chainManager.isRealtime,
      )

      chainFetcher.sourceManager->SourceManager.onReorg(
        ~rollbackTargetBlock=rollbackTargetBlockNumber,
      )

      state->IndexerState.foundReorgDepth(~chain, ~rollbackTargetBlockNumber)
      // Rendezvous with the processing loop: whichever of {depth found, loop
      // idle} happens last triggers the rollback; the earlier one finds the
      // other condition unmet and bails here.
      state->launchRollback
    // Reached when a batch finished (loop idle) while the reorg depth wasn't
    // found yet. Wait for the ReorgDetected branch above to find it and re-kick.
    | FindingReorgDepth => ()
    | FoundReorgDepth(_) if state->IndexerState.isProcessing =>
      Logging.info("Waiting for batch to finish processing before executing rollback")
    | FoundReorgDepth({chain: reorgChain, rollbackTargetBlockNumber}) =>
      await executeRollback(state, ~reorgChain, ~rollbackTargetBlockNumber)
    }
  } catch {
  | exn => IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=unexpectedErrorMsg))
  }

and executeRollback = async (state: IndexerState.t, ~reorgChain, ~rollbackTargetBlockNumber) => {
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

  state->IndexerState.completeRollback(~eventsProcessedDiffByChain, ~chainManager)
  state->launchFetchAllChains
  state->launchProcessing
}

and launchFetchAllChains = (state: IndexerState.t) =>
  launch(state, () => checkAndFetchAllChains(state, ~stateId=state.epoch))
and launchFetchChain = (state: IndexerState.t, chain) =>
  launch(state, () => checkAndFetchForChain(state, chain, ~stateId=state.epoch))
and launchProcessing = (state: IndexerState.t) => launch(state, () => startProcessing(state))
and launchRollback = (state: IndexerState.t) => launch(state, () => rollback(state))

// Kick off the indexer loops.
let start = (state: IndexerState.t) => {
  state->launchFetchAllChains
  state->launchProcessing
}
