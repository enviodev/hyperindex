// The reorg rollback state machine. Re-enters fetch/process/rollback through
// the injected schedule* effects.

/**
Finds the last known valid block number below the reorg block
If not found, returns the highest block below threshold
*/
let getLastKnownValidBlock = async (
  chainState: ChainState.t,
  ~reorgBlockNumber: int,
  ~isRealtime: bool,
) => {
  // Don't include the reorg block itself — different source instances
  // may have mismatching hashes at the head, so we always rollback
  // the block where we detected the reorg.
  let scannedBlockNumbers =
    chainState
    ->ChainState.reorgDetection
    ->ReorgDetection.getThresholdBlockNumbersBelowBlock(
      ~blockNumber=reorgBlockNumber,
      ~knownHeight=(chainState->ChainState.fetchState).knownHeight,
    )

  switch scannedBlockNumbers {
  | [] => chainState->ChainState.getHighestBlockBelowThreshold
  | _ => {
      let blockNumbersAndHashes = await chainState
      ->ChainState.sourceManager
      ->SourceManager.getBlockHashes(~blockNumbers=scannedBlockNumbers, ~isRealtime)

      switch chainState
      ->ChainState.reorgDetection
      ->ReorgDetection.getLatestValidScannedBlock(~blockNumbersAndHashes) {
      | Some(blockNumber) => blockNumber
      | None => chainState->ChainState.getHighestBlockBelowThreshold
      }
    }
  }
}

let rec rollback = async (
  state: IndexerState.t,
  ~scheduleFetchAllChains,
  ~scheduleProcessing,
  ~scheduleRollback,
) =>
  // Owns its error boundary: launch doesn't catch, so a failure mid-rollback
  // must stop the indexer.
  try {
    switch state->IndexerState.rollbackState {
    | NoRollback | RollbackReady(_) =>
      JsError.throwWithMessage("Internal error: Rollback initiated with invalid state")
    | ReorgDetected({chain, blockNumber: reorgBlockNumber}) =>
      let chainState = state->IndexerState.getChainState(~chain)

      state->IndexerState.enterFindingReorgDepth
      let rollbackTargetBlockNumber = await chainState->getLastKnownValidBlock(
        ~reorgBlockNumber,
        ~isRealtime=state->IndexerState.isRealtime,
      )

      chainState
      ->ChainState.sourceManager
      ->SourceManager.onReorg(~rollbackTargetBlock=rollbackTargetBlockNumber)

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

  let chainState = state->IndexerState.getChainState(~chain=reorgChain)

  let logger = Logging.createChildFrom(
    ~logger=chainState->ChainState.logger,
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
  await state->Writing.flush

  let rollbackTargetCheckpointId = {
    switch await (state->IndexerState.persistence).storage.getRollbackTargetCheckpoint(
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
    let rollbackProgressDiff = await (
      state->IndexerState.persistence
    ).storage.getRollbackProgressDiff(~rollbackTargetCheckpointId)
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

  state
  ->IndexerState.chainStates
  ->Utils.Dict.forEach(cs => {
    let chainId = (cs->ChainState.chainConfig).id
    cs->ChainState.rollback(
      ~newProgressBlockNumber=newProgressBlockNumberPerChain->Utils.Dict.dangerouslyGetByIntNonOption(
        chainId,
      ),
      ~eventsProcessedDiff=eventsProcessedDiffByChain->Utils.Dict.dangerouslyGetByIntNonOption(
        chainId,
      ),
      ~rollbackTargetBlockNumber,
      ~isReorgChain=chainId === reorgChainId,
    )
  })

  let diff = await state->InMemoryStore.prepareRollbackDiff(
    ~rollbackTargetCheckpointId,
    ~rollbackDiffCheckpointId=state->IndexerState.committedCheckpointId->BigInt.add(1n),
    ~progressBlockNumberByChainId=newProgressBlockNumberPerChain,
  )

  logger->Logging.childTrace({
    "msg": "Finished rollback on reorg",
    "entityChanges": {
      "deleted": diff["deletedEntities"],
      "upserted": diff["setEntities"],
    },
    "rollbackedEvents": rollbackedProcessedEvents.contents,
    "beforeCheckpointId": state->IndexerState.committedCheckpointId,
    "targetCheckpointId": rollbackTargetCheckpointId,
  })
  Prometheus.RollbackSuccess.increment(
    ~timeSeconds=Hrtime.timeSince(startTime)->Hrtime.toSecondsFloat,
    ~rollbackedProcessedEvents=rollbackedProcessedEvents.contents,
  )

  state->IndexerState.completeRollback(~eventsProcessedDiffByChain)
  scheduleFetchAllChains()
  scheduleProcessing()
}
