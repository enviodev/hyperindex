// The reorg rollback state machine. Re-enters fetch/process/rollback through
// the injected schedule* effects.

let rec rollback = async (
  state: IndexerState.t,
  ~scheduleFetchAllChains,
  ~scheduleProcessing,
  ~scheduleRollback,
) =>
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
      scheduleRollback()
    // Reached when a batch finished (loop idle) while the reorg depth wasn't
    // found yet. Wait for the ReorgDetected branch above to find it and re-kick.
    | FindingReorgDepth => ()
    | FoundReorgDepth(_) if state->IndexerState.isProcessing =>
      Logging.info("Waiting for batch to finish processing before executing rollback")
    | FoundReorgDepth({chain: reorgChain, rollbackTargetBlockNumber}) =>
      await executeRollback(
        state,
        ~reorgChain,
        ~rollbackTargetBlockNumber,
        ~scheduleFetchAllChains,
        ~scheduleProcessing,
      )
    }
  } catch {
  | exn =>
    IndexerState.errorExit(state, exn->ErrorHandling.make(~msg=IndexerState.unexpectedErrorMsg))
  }

and executeRollback = async (
  state: IndexerState.t,
  ~reorgChain,
  ~rollbackTargetBlockNumber,
  ~scheduleFetchAllChains,
  ~scheduleProcessing,
) => {
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
  await state.inMemoryStore->InMemoryStore.flush

  let rollbackTargetCheckpointId = {
    switch await state.persistence.storage.getRollbackTargetCheckpoint(
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
    let rollbackProgressDiff = await state.persistence.storage.getRollbackProgressDiff(
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
        // Both dicts are populated together per progress-diff row above, so a
        // chain present in newProgressBlockNumberPerChain always has a diff here.
        ->Option.getOrThrow(~message="Missing events-processed diff for rolled-back chain")

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

  let diff = await state.inMemoryStore->InMemoryStore.prepareRollbackDiff(
    ~persistence=state.persistence,
    ~rollbackTargetCheckpointId,
    ~rollbackDiffCheckpointId=state.inMemoryStore.committedCheckpointId->BigInt.add(1n),
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
    "beforeCheckpointId": state.inMemoryStore.committedCheckpointId,
    "targetCheckpointId": rollbackTargetCheckpointId,
  })
  Prometheus.RollbackSuccess.increment(
    ~timeSeconds=Hrtime.timeSince(startTime)->Hrtime.toSecondsFloat,
    ~rollbackedProcessedEvents=rollbackedProcessedEvents.contents,
  )

  state->IndexerState.completeRollback(~eventsProcessedDiffByChain, ~chainManager)
  scheduleFetchAllChains()
  scheduleProcessing()
}
