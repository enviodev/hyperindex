// Throttled prune of stale entity-history rows below the safe checkpoint.
let schedule = (state: IndexerState.t) => {
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
