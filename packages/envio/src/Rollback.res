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
      ~knownHeight=chainState->ChainState.knownHeight,
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
  ~scheduleFetch,
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
      Logging.trace("Waiting for batch to finish processing before executing rollback")
    | FoundReorgDepth({chain: reorgChain, rollbackTargetBlockNumber}) =>
      await executeRollback(
        state,
        ~reorgChain,
        ~rollbackTargetBlockNumber,
        ~scheduleFetch,
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
  ~scheduleFetch,
  ~scheduleProcessing,
) => {
  let startTime = Performance.now()

  // Not derived from the reorg chain's logger: that would bind its chainId onto
  // every line, colliding with the per-chain chainId on the "Rollbacked" logs.
  // The reorg chain is identified by the reorgChain param instead.
  let logger = Logging.createChild(
    ~params={
      "action": "Rollback",
      "reorgChain": reorgChain,
      "targetBlockNumber": rollbackTargetBlockNumber,
    },
  )
  logger->Logging.childInfo("Started rollback on reorg")
  state
  ->IndexerState.getChainState(~chain=reorgChain)
  ->ChainState.setRollbackTargetBlock(~blockNumber=rollbackTargetBlockNumber)

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

  let rolledBackChains = []
  state
  ->IndexerState.chainStates
  ->Utils.Dict.forEach(cs => {
    let chainId = (cs->ChainState.chainConfig).id
    let fromBlock = cs->ChainState.committedProgressBlockNumber
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
    let toBlock = cs->ChainState.committedProgressBlockNumber
    if fromBlock !== toBlock {
      rolledBackChains
      ->Array.push({
        "chainId": chainId,
        "fromBlock": fromBlock,
        "toBlock": toBlock,
        "rollbackedEvents": eventsProcessedDiffByChain
        ->Utils.Dict.dangerouslyGetByIntNonOption(chainId)
        ->Option.getOr(0.),
      })
      ->ignore
    }
  })

  let diff = await state->InMemoryStore.prepareRollbackDiff(
    ~rollbackTargetCheckpointId,
    ~rollbackDiffCheckpointId=state->IndexerState.committedCheckpointId->BigInt.add(1n),
    ~progressBlockNumberByChainId=newProgressBlockNumberPerChain,
  )

  rolledBackChains->Array.forEach(chain => {
    logger->Logging.childInfo({
      "msg": "Rollbacked",
      "chainId": chain["chainId"],
      "fromBlock": chain["fromBlock"],
      "toBlock": chain["toBlock"],
      "rollbackedEvents": chain["rollbackedEvents"],
    })
  })
  logger->Logging.childTrace({
    "msg": "Rollback entity changes",
    "deleted": diff["deletedEntities"],
    "upserted": diff["setEntities"],
  })
  state->IndexerState.recordRollbackSuccess(
    ~timeSeconds=Performance.secondsSince(startTime),
    ~rollbackedProcessedEvents=rollbackedProcessedEvents.contents,
  )

  state->IndexerState.completeRollback(~eventsProcessedDiffByChain)
  scheduleFetch()
  scheduleProcessing()
}
