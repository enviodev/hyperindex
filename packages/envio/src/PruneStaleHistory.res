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
  safeCheckpoints: SafeCheckpoints.t,
  concurrent: array<Internal.entityConfig>,
  forced: array<Internal.entityConfig>,
}

// Where each chain's history may be pruned back to.
//
// A rollback only ever deletes a chain's rows down to that chain's own floor,
// which is derived from its own reorg and so never reaches below its own safe
// checkpoint. Each chain can therefore prune to its own, and a chain that has
// nothing safe yet only holds itself back.
//
// Unless the schema has a cross-chain entity: a reorg on any chain then rolls
// every chain back to one checkpoint, which can sit below another chain's safe
// point, so the lowest is the only bound every chain agrees on.
let selectSafeCheckpoints = (state: IndexerState.t) => {
  let byChain = state->IndexerState.getSafeCheckpointIdByChain
  if state->IndexerState.config->Config.isIsolatedMultichain {
    SafeCheckpoints.PerChain(
      byChain->Array.filter(((_, checkpointId)) =>
        checkpointId !== Internal.initialCheckpointId
      ),
    )
  } else {
    // A chain with nothing safe yet reports the initial checkpoint, which is
    // below every other chain's and so pins the bound there — the minimum can't
    // be seeded with it without reading as "no value yet" and losing that.
    SafeCheckpoints.EveryChain(
      byChain
      ->Array.reduce(None, (lowest, (_, checkpointId)) =>
        switch lowest {
        | Some(lowest) => Some(Pervasives.min(lowest, checkpointId))
        | None => Some(checkpointId)
        }
      )
      ->Option.getOr(Internal.initialCheckpointId),
    )
  }
}

// Nothing to prune yet: no chain has a safe checkpoint of its own, or the one
// bounding them all is still the initial checkpoint. Checked before a pass runs
// so an empty one doesn't spend the entity's prune interval.
let hasNothingToPrune = (safeCheckpoints: SafeCheckpoints.t) =>
  switch safeCheckpoints {
  | PerChain([]) => true
  | EveryChain(checkpointId) => checkpointId === Internal.initialCheckpointId
  | PerChain(_) => false
  }

let selectFrom = (
  ~allEntities: array<Internal.entityConfig>,
  ~lastPrunedAtMillis: dict<float>,
  ~writtenEntityNames: Utils.Set.t<string>,
  ~isRollback,
  ~nowMillis,
  ~intervalMillis,
  ~safeCheckpoints,
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
    safeCheckpoints,
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
    switch state->selectSafeCheckpoints {
    | safeCheckpoints if safeCheckpoints->hasNothingToPrune => None
    | safeCheckpoints =>
      Some(
        selectFrom(
          ~allEntities=(state->IndexerState.persistence).allEntities,
          ~lastPrunedAtMillis=state->IndexerState.lastPrunedAtMillis,
          ~writtenEntityNames,
          ~isRollback,
          ~nowMillis=Date.now(),
          ~intervalMillis=Env.ThrottleWrites.pruneStaleDataIntervalMillis->Int.toFloat,
          ~safeCheckpoints,
        ),
      )
    }
  } else {
    None
  }
}

let pruneEntity = async (
  state: IndexerState.t,
  ~entityConfig: Internal.entityConfig,
  ~safeCheckpoints,
) => {
  let persistence = state->IndexerState.persistence
  let timeRef = Performance.now()
  // Recorded for failures too, so a failing prune retries on the same
  // interval instead of on every write.
  state->IndexerState.lastPrunedAtMillis->Dict.set(entityConfig.name, Date.now())
  switch await persistence.storage.pruneStaleEntityHistory(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
    ~chainIdColumn=entityConfig.table->Table.getPgChainIdColumn,
    ~safeCheckpoints,
  ) {
  | () =>
    state->IndexerState.recordHistoryPrune(
      ~timeSeconds=Performance.secondsSince(timeRef),
      ~entityName=entityConfig.name,
    )
  | exception exn =>
    // Pruning is cleanup; a failure must not fail the write loop.
    Logging.createChild(
      ~params={"entityName": entityConfig.name},
    )->Logging.childErrorWithExn(exn->Utils.prettifyExn, `Failed to prune stale entity history`)
  }
}

let pruneEntities = (state: IndexerState.t, ~entities, ~safeCheckpoints) =>
  entities->Utils.Array.awaitEach(entityConfig => state->pruneEntity(~entityConfig, ~safeCheckpoints))

let pruneCheckpoints = async (state: IndexerState.t, ~safeCheckpoints) => {
  switch await (state->IndexerState.persistence).storage.pruneStaleCheckpoints(~safeCheckpoints) {
  | () => ()
  | exception exn =>
    Logging.errorWithExn(exn->Utils.prettifyExn, `Failed to prune stale checkpoints`)
  }
}

let runConcurrent = async (state: IndexerState.t, ~targets) => {
  switch targets {
  | Some({safeCheckpoints, concurrent}) if concurrent->Utils.Array.notEmpty =>
    await pruneCheckpoints(state, ~safeCheckpoints)
    await pruneEntities(state, ~entities=concurrent, ~safeCheckpoints)
  | Some(_) | None => ()
  }
}

let runForced = async (state: IndexerState.t, ~targets) => {
  switch targets {
  | Some({safeCheckpoints, concurrent, forced}) if forced->Utils.Array.notEmpty =>
    // When nothing ran concurrently (eg a rollback write), checkpoint pruning
    // lands here, after the write, so it never overlaps a rollback transaction.
    if concurrent->Utils.Array.isEmpty {
      await pruneCheckpoints(state, ~safeCheckpoints)
    }
    await pruneEntities(state, ~entities=forced, ~safeCheckpoints)
  | Some(_) | None => ()
  }
}
