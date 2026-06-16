// Leaf effects of the indexer loop: they read state/ctx and write to the store,
// persistence or the process, but never re-enter the fetch/process/rollback loop.

let stageChainMetadata = (state: IndexerState.t) => {
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

// Flush, then exit unless a reorg landed during the flush (which parks a rollback
// to recover instead).
let exitOnCaughtUp = async (state: IndexerState.t) => {
  stageChainMetadata(state)
  await state.ctx.inMemoryStore->InMemoryStore.flush
  if !state.isStopped && !state.isRollingBack {
    Logging.info("Exiting with success")
    NodeJs.process->NodeJs.exitWithCode(Success)
  }
}

let pruneStaleEntityHistory = (state: IndexerState.t) => {
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
