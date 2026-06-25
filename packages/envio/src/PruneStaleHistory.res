// Throttled prune of stale entity-history rows below the safe checkpoint.

let runPrune = async (state: IndexerState.t) => {
  switch state->IndexerState.getSafeCheckpointId {
  | None => ()
  | Some(safeCheckpointId) =>
    let persistence = state->IndexerState.persistence
    await persistence.storage.pruneStaleCheckpoints(~safeCheckpointId)

    for idx in 0 to persistence.allEntities->Array.length - 1 {
      if idx !== 0 {
        // Add some delay between entities
        // To unblock the pg client if it's needed for something else
        await Utils.delay(1000)
      }
      let entityConfig = persistence.allEntities->Array.getUnsafe(idx)
      let timeRef = Performance.now()
      try {
        let () = await persistence.storage.pruneStaleEntityHistory(
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
        ~timeSeconds=Performance.secondsSince(timeRef),
        ~entityName=entityConfig.name,
      )
    }
  }
}

let schedule = (state: IndexerState.t) =>
  state->IndexerState.pruneStaleEntityHistoryThrottler->Throttler.schedule(() => runPrune(state))
