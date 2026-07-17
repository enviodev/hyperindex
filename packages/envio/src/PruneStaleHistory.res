// Prune of stale entity-history rows below the safe checkpoint.
//
// Pruning must never run concurrently with a write to the same entity's history
// table: the prune's anchor deletion relies on "no history after the safe
// checkpoint", which a concurrently committing batch can falsify, losing the
// anchor and breaking a later rollback. The write loop enforces the safety by
// running the concurrent group only for entities absent from the batch being
// written (and awaiting it before the next write starts), and the forced group
// alone after the write.

let maxEntitiesPerWrite = 5
let forcedIntervalMultiplier = 5.

type targets = {
  safeCheckpointId: Internal.checkpointId,
  concurrent: array<Internal.entityConfig>,
  forced: array<Internal.entityConfig>,
}

let selectFrom = (
  ~allEntities: array<Internal.entityConfig>,
  ~lastPrunedAtMillis: dict<float>,
  ~writtenEntityNames: Utils.Set.t<string>,
  ~isRollback,
  ~nowMillis,
  ~intervalMillis,
  ~safeCheckpointId,
) => {
  let lastPrunedAt = (entityConfig: Internal.entityConfig) =>
    lastPrunedAtMillis
    ->Utils.Dict.dangerouslyGetNonOption(entityConfig.name)
    ->Option.getOr(0.)
  let byOldestPrune = (a, b) => lastPrunedAt(a) -. lastPrunedAt(b)

  let candidates = allEntities->Array.filter(entityConfig => entityConfig.storage.postgres)

  let concurrent = isRollback
    ? []
    : candidates
      ->Array.filter(entityConfig =>
        !(writtenEntityNames->Utils.Set.has(entityConfig.name)) &&
        nowMillis -. lastPrunedAt(entityConfig) >= intervalMillis
      )
      ->Array.toSorted(byOldestPrune)
      ->Array.slice(~start=0, ~end=maxEntitiesPerWrite)

  let concurrentNames = Utils.Set.make()
  concurrent->Array.forEach(entityConfig =>
    concurrentNames->Utils.Set.add(entityConfig.name)->ignore
  )

  let forced =
    candidates
    ->Array.filter(entityConfig =>
      !(concurrentNames->Utils.Set.has(entityConfig.name)) &&
      nowMillis -. lastPrunedAt(entityConfig) >= intervalMillis *. forcedIntervalMultiplier
    )
    ->Array.toSorted(byOldestPrune)
    ->Array.slice(~start=0, ~end=maxEntitiesPerWrite)

  {safeCheckpointId, concurrent, forced}
}

let select = (state: IndexerState.t, ~writtenEntityNames, ~isRollback) => {
  let config = state->IndexerState.config
  if config->Config.shouldPruneHistory(~isInReorgThreshold=state->IndexerState.isInReorgThreshold) {
    switch state->IndexerState.getSafeCheckpointId {
    | None => None
    | Some(safeCheckpointId) =>
      Some(
        selectFrom(
          ~allEntities=(state->IndexerState.persistence).allEntities,
          ~lastPrunedAtMillis=state->IndexerState.lastPrunedAtMillis,
          ~writtenEntityNames,
          ~isRollback,
          ~nowMillis=Date.now(),
          ~intervalMillis=Env.ThrottleWrites.pruneStaleDataIntervalMillis->Int.toFloat,
          ~safeCheckpointId,
        ),
      )
    }
  } else {
    None
  }
}

let pruneEntities = async (state: IndexerState.t, ~entities, ~safeCheckpointId) => {
  let persistence = state->IndexerState.persistence
  for idx in 0 to entities->Array.length - 1 {
    let entityConfig: Internal.entityConfig = entities->Array.getUnsafe(idx)
    let timeRef = Performance.now()
    switch await persistence.storage.pruneStaleEntityHistory(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
      ~safeCheckpointId,
    ) {
    | () =>
      state->IndexerState.lastPrunedAtMillis->Dict.set(entityConfig.name, Date.now())
      Prometheus.RollbackHistoryPrune.increment(
        ~timeSeconds=Performance.secondsSince(timeRef),
        ~entityName=entityConfig.name,
      )
    | exception exn =>
      // Pruning is cleanup; a failure must not fail the write loop.
      Logging.createChild(
        ~params={
          "entityName": entityConfig.name,
          "safeCheckpointId": safeCheckpointId,
        },
      )->Logging.childErrorWithExn(exn->Utils.prettifyExn, `Failed to prune stale entity history`)
    }
  }
}

let runConcurrent = async (state: IndexerState.t, ~targets) => {
  switch targets {
  | Some({safeCheckpointId, concurrent, forced}) =>
    if concurrent->Utils.Array.notEmpty || forced->Utils.Array.notEmpty {
      switch await (state->IndexerState.persistence).storage.pruneStaleCheckpoints(
        ~safeCheckpointId,
      ) {
      | () => ()
      | exception exn =>
        Logging.createChild(
          ~params={"safeCheckpointId": safeCheckpointId},
        )->Logging.childErrorWithExn(exn->Utils.prettifyExn, `Failed to prune stale checkpoints`)
      }
    }
    await pruneEntities(state, ~entities=concurrent, ~safeCheckpointId)
  | None => ()
  }
}

let runForced = async (state: IndexerState.t, ~targets) => {
  switch targets {
  | Some({safeCheckpointId, forced}) =>
    await pruneEntities(state, ~entities=forced, ~safeCheckpointId)
  | None => ()
  }
}
