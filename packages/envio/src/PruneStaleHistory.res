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
  let byOldestPrune = ((a, _), (b, _)) => a -. b
  let toEntities = candidates => candidates->Array.map(((_, entityConfig)) => entityConfig)

  let concurrentCandidates = []
  let forcedCandidates = []
  allEntities->Array.forEach(entityConfig => {
    if entityConfig.storage.postgres {
      let lastPrunedAt =
        lastPrunedAtMillis
        ->Utils.Dict.dangerouslyGetNonOption(entityConfig.name)
        ->Option.getOr(0.)
      if (
        !isRollback &&
        !(writtenEntityNames->Utils.Set.has(entityConfig.name)) &&
        nowMillis -. lastPrunedAt >= intervalMillis
      ) {
        concurrentCandidates->Array.push((lastPrunedAt, entityConfig))
      } else if nowMillis -. lastPrunedAt >= intervalMillis *. forcedIntervalMultiplier {
        forcedCandidates->Array.push((lastPrunedAt, entityConfig))
      }
    }
  })

  let sortedConcurrent = concurrentCandidates->Array.toSorted(byOldestPrune)
  // Concurrent candidates beyond the cap are not selected, so the starved
  // ones among them still qualify for the forced group.
  for idx in maxEntitiesPerWrite to sortedConcurrent->Array.length - 1 {
    let (lastPrunedAt, _) = sortedConcurrent->Array.getUnsafe(idx)
    if nowMillis -. lastPrunedAt >= intervalMillis *. forcedIntervalMultiplier {
      forcedCandidates->Array.push(sortedConcurrent->Array.getUnsafe(idx))
    }
  }

  {
    safeCheckpointId,
    concurrent: sortedConcurrent->Array.slice(~start=0, ~end=maxEntitiesPerWrite)->toEntities,
    forced: forcedCandidates
    ->Array.toSorted(byOldestPrune)
    ->Array.slice(~start=0, ~end=maxEntitiesPerWrite)
    ->toEntities,
  }
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
    // Recorded for failures too, so a failing prune retries on the same
    // interval instead of on every write.
    state->IndexerState.lastPrunedAtMillis->Dict.set(entityConfig.name, Date.now())
    switch await persistence.storage.pruneStaleEntityHistory(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
      ~safeCheckpointId,
    ) {
    | () =>
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

let pruneCheckpoints = async (state: IndexerState.t, ~safeCheckpointId) => {
  switch await (state->IndexerState.persistence).storage.pruneStaleCheckpoints(~safeCheckpointId) {
  | () => ()
  | exception exn =>
    Logging.createChild(~params={"safeCheckpointId": safeCheckpointId})->Logging.childErrorWithExn(
      exn->Utils.prettifyExn,
      `Failed to prune stale checkpoints`,
    )
  }
}

let runConcurrent = async (state: IndexerState.t, ~targets) => {
  switch targets {
  | Some({safeCheckpointId, concurrent}) if concurrent->Utils.Array.notEmpty =>
    await pruneCheckpoints(state, ~safeCheckpointId)
    await pruneEntities(state, ~entities=concurrent, ~safeCheckpointId)
  | Some(_) | None => ()
  }
}

let runForced = async (state: IndexerState.t, ~targets) => {
  switch targets {
  | Some({safeCheckpointId, concurrent, forced}) if forced->Utils.Array.notEmpty =>
    // When nothing ran concurrently (eg a rollback write), checkpoint pruning
    // lands here, after the write, so it never overlaps a rollback transaction.
    if concurrent->Utils.Array.isEmpty {
      await pruneCheckpoints(state, ~safeCheckpointId)
    }
    await pruneEntities(state, ~entities=forced, ~safeCheckpointId)
  | Some(_) | None => ()
  }
}
