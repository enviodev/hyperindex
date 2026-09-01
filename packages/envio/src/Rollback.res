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
  // Before the search, not after: it re-fetches the scanned hashes through the
  // sources, and a source answering from a cache it filled on the orphaned
  // chain would confirm blocks that no longer exist - stopping the rollback
  // short of the real fork.
  chainState->ChainState.sourceManager->SourceManager.onReorg

  // Don't include the reorg block itself - different source instances
  // may have mismatching hashes at the head, so we always rollback
  // the block where we detected the reorg.
  let scannedBlockNumbers =
    chainState->ChainState.getReorgThresholdBlockNumbersBelow(~blockNumber=reorgBlockNumber)

  switch scannedBlockNumbers {
  | [] => chainState->ChainState.getHighestBlockBelowThreshold
  | _ => {
      let blockStore = await chainState
      ->ChainState.sourceManager
      ->SourceManager.getBlockHashes(~blockNumbers=scannedBlockNumbers, ~isRealtime)

      switch chainState->ChainState.getLatestValidScannedBlock(
        ~blockStore,
        ~blockNumbers=scannedBlockNumbers,
      ) {
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
    | ReorgDetected({chainId, blockNumber: reorgBlockNumber}) =>
      let chainState = state->IndexerState.getChainState(~chainId)

      state->IndexerState.enterFindingReorgDepth

      let rollbackTargetBlockNumber = await chainState->getLastKnownValidBlock(
        ~reorgBlockNumber,
        ~isRealtime=state->IndexerState.isRealtime,
      )

      state->IndexerState.foundReorgDepth(~chainId, ~rollbackTargetBlockNumber)
      // Rendezvous with the processing loop: whichever of {depth found, loop
      // idle} happens last triggers the rollback; the earlier one finds the
      // other condition unmet and bails here.
      scheduleRollback()
    // Reached when a batch finished (loop idle) while the reorg depth wasn't
    // found yet. Wait for the ReorgDetected branch above to find it and re-kick.
    | FindingReorgDepth => ()
    | FoundReorgDepth(_) if state->IndexerState.isProcessing =>
      Logging.trace("Waiting for batch to finish processing before executing rollback")
    | FoundReorgDepth({chainId: reorgChain, rollbackTargetBlockNumber}) =>
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
  ->IndexerState.getChainState(~chainId=reorgChain)
  ->ChainState.setRollbackTargetBlock(~blockNumber=rollbackTargetBlockNumber)

  // Finish pending batch writes first: the target checkpoint, the progress
  // diff and the rollback diff below must all be computed from the same db
  // state. Otherwise an in-flight batch lands after the progress reads and
  // its entity changes get reverted without the chain progress being
  // rolled back, so the events are never reprocessed.
  await state->Writing.flush

  let rollbackTargetCheckpointId = {
    switch await (state->IndexerState.persistence).storage.getRollbackTargetCheckpoint(
      ~reorgChainId=reorgChain,
      ~lastKnownValidBlockNumber=rollbackTargetBlockNumber,
    ) {
    | Some(checkpointId) => checkpointId
    | None => 0n
    }
  }

  // The diff computed here replaces a pending one rather than merging with it,
  // so its deletes have to cover everything that one would have deleted. A lower
  // target covers a higher one within the same scope, but two scopes naming
  // different chains only meet at Global. The flush above leaves a diff pending
  // only when no batch has come along to carry it.
  let (scope, rollbackTargetCheckpointId) = {
    let scope: RollbackScope.t =
      state->IndexerState.config->Config.isIsolatedMultichain ? Isolated(reorgChain) : Global
    switch state->IndexerState.pendingRollback {
    | None => (scope, rollbackTargetCheckpointId)
    | Some({scope: pendingScope, targetCheckpointId: pendingTarget}) =>
      let target = Pervasives.min(rollbackTargetCheckpointId, pendingTarget)
      if scope == pendingScope {
        (scope, target)
      } else {
        logger->Logging.childInfo(
          "Widening the rollback to every chain: another chain's rollback is still unwritten",
        )
        (Global, target)
      }
    }
  }

  let progressDiffByChain: dict<ChainState.progressDiff> = Dict.make()
  let rollbackedProcessedEvents = ref(0.)

  {
    let rollbackProgressDiff = await (
      state->IndexerState.persistence
    ).storage.getRollbackProgressDiff(~scope, ~rollbackTargetCheckpointId)
    for idx in 0 to rollbackProgressDiff->Array.length - 1 {
      let diff = rollbackProgressDiff->Array.getUnsafe(idx)
      let eventsProcessed = Float.fromString(diff["events_processed_diff"])->Option.getOrThrow
      rollbackedProcessedEvents := rollbackedProcessedEvents.contents +. eventsProcessed
      progressDiffByChain->ChainId.Dict.set(
        diff["chain_id"],
        {
          blockNumber: if rollbackTargetCheckpointId === 0n && diff["chain_id"] === reorgChain {
            Pervasives.min(diff["new_progress_block_number"], rollbackTargetBlockNumber)
          } else {
            diff["new_progress_block_number"]
          },
          eventsProcessed,
        },
      )
    }
  }

  // Where the rollback leaves each chain it moved, written with the diff: the
  // batch that carries it may belong to a chain the rollback never touched.
  let rolledBackChains: array<InternalTable.Chains.progressedChain> = []
  let rolledBackAddresses = []
  state
  ->IndexerState.chainStates
  ->Utils.Dict.forEach(cs => {
    let chainId = (cs->ChainState.chainConfig).id
    let fromBlock = cs->ChainState.committedProgressBlockNumber
    let progressDiff = progressDiffByChain->ChainId.Dict.dangerouslyGetNonOption(chainId)
    let killedAddresses = cs->ChainState.rollback(
      ~rolledBackTo=switch progressDiff {
      | Some(progressDiff) => RecomputedProgress(progressDiff)
      | None => chainId === reorgChain ? ForkBlock(rollbackTargetBlockNumber) : Untouched
      },
    )
    rolledBackAddresses->Array.pushMany(killedAddresses)->ignore
    let toBlock = cs->ChainState.committedProgressBlockNumber
    if fromBlock !== toBlock {
      rolledBackChains
      ->Array.push({
        chainId,
        progressBlockNumber: toBlock,
        sourceBlockNumber: cs->ChainState.knownHeight,
        totalEventsProcessed: cs->ChainState.numEventsProcessed,
      })
      ->ignore
      logger->Logging.childInfo({
        "msg": "Rollbacked",
        "chainId": chainId,
        "fromBlock": fromBlock,
        "toBlock": toBlock,
        "rollbackedEvents": progressDiff->Option.mapOr(0., diff => diff.eventsProcessed),
      })
    }
  })

  let diff = await state->InMemoryStore.prepareRollbackDiff(
    ~rollbackScope=scope,
    ~rollbackTargetCheckpointId,
    ~rollbackDiffCheckpointId=state->IndexerState.committedCheckpointId->BigInt.add(1n),
    ~progressedChains=rolledBackChains,
    ~rolledBackAddresses,
  )

  logger->Logging.childTrace({
    "msg": "Rollback entity changes",
    "deleted": diff["deletedEntities"],
    "upserted": diff["setEntities"],
  })
  state->IndexerState.recordRollbackSuccess(
    ~timeSeconds=Performance.secondsSince(startTime),
    ~rollbackedProcessedEvents=rollbackedProcessedEvents.contents,
  )

  state->IndexerState.completeRollback(
    ~eventsProcessedDiffByChain=progressDiffByChain->Utils.Dict.mapValues(diff =>
      diff.eventsProcessed
    ),
  )
  scheduleFetch()
  scheduleProcessing()
}
