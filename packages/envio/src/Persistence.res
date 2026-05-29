// A module for the persistence layer
// This is currently in a WIP state
// but in the future we should make all DB and in-memory state
// interactions to this layer with DI and easy for testing.
// Currently there are quite many code spread across
// DbFunctions, Db, Migrations, InMemoryStore modules which use codegen code directly.

// The type reflects an cache table in the db
// It might be present even if the effect is not used in the application
type effectCacheRecord = {
  effectName: string,
  // Number of rows in the table
  mutable count: int,
}

type initialChainState = {
  id: int,
  startBlock: int,
  endBlock: option<int>,
  maxReorgDepth: int,
  progressBlockNumber: int,
  numEventsProcessed: float,
  firstEventBlockNumber: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  indexingAddresses: array<Internal.indexingAddress>,
  sourceBlockNumber: int,
}

type initialState = {
  cleanRun: bool,
  cache: dict<effectCacheRecord>,
  chains: array<initialChainState>,
  checkpointId: Internal.checkpointId,
  // Needed to keep reorg detection logic between restarts
  reorgCheckpoints: array<Internal.reorgCheckpoint>,
  // Public config snapshot read from envio_info, used by `Persistence.init`
  // to compat-check a resume against the running config. None when the
  // schema pre-dates envio_info or the row is missing — `init` treats that
  // as a version mismatch.
  envioInfo: option<JSON.t>,
}

type operator = [#">" | #"=" | #"<"]

type updatedEffectCache = {
  effect: Internal.effect,
  items: array<Internal.effectCacheItem>,
  shouldInitialize: bool,
}

type updatedEntity = {
  entityConfig: Internal.entityConfig,
  updates: array<Internal.inMemoryStoreEntityUpdate<Internal.entity>>,
}

type storage = {
  // Identifier used as the `storage` label on Prometheus metrics.
  name: string,
  // Should return true if we already have persisted data
  // and we can skip initialization
  isInitialized: unit => promise<bool>,
  // Should initialize the storage so we can start interacting with it
  // Eg create connection, schema, tables, etc. `envioInfo` is opaque JSON
  // persisted as part of the same transaction so a fresh schema always
  // carries a matching row — storage doesn't interpret it.
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Table.enumConfig<Table.enum>>=?,
    ~envioInfo: JSON.t,
  ) => promise<initialState>,
  resumeInitialState: unit => promise<initialState>,
  @raises("StorageError")
  loadByIdsOrThrow: 'item. (
    ~ids: array<string>,
    ~table: Table.table,
    ~rowsSchema: S.t<array<'item>>,
  ) => promise<array<'item>>,
  @raises("StorageError")
  loadByFieldOrThrow: 'item 'value. (
    ~fieldName: string,
    ~fieldSchema: S.t<'value>,
    ~fieldValue: 'value,
    ~operator: operator,
    ~table: Table.table,
    ~rowsSchema: S.t<array<'item>>,
  ) => promise<array<'item>>,
  // This is to download cache from the database to .envio/cache
  dumpEffectCache: unit => promise<unit>,
  reset: unit => promise<unit>,
  // Update chain metadata
  setChainMeta: dict<InternalTable.Chains.metaFields> => promise<unknown>,
  // Prune old checkpoints
  pruneStaleCheckpoints: (~safeCheckpointId: Internal.checkpointId) => promise<unit>,
  // Prune stale entity history
  pruneStaleEntityHistory: (
    ~entityName: string,
    ~entityIndex: int,
    ~safeCheckpointId: Internal.checkpointId,
  ) => promise<unit>,
  // Get rollback target checkpoint
  getRollbackTargetCheckpoint: (
    ~reorgChainId: int,
    ~lastKnownValidBlockNumber: int,
  ) => promise<option<Internal.checkpointId>>,
  // Get rollback progress diff
  getRollbackProgressDiff: (
    ~rollbackTargetCheckpointId: Internal.checkpointId,
  ) => promise<
    array<{
      "chain_id": int,
      "events_processed_diff": string,
      "new_progress_block_number": int,
    }>,
  >,
  // Get rollback data for entity
  getRollbackData: (
    ~entityConfig: Internal.entityConfig,
    ~rollbackTargetCheckpointId: Internal.checkpointId,
  ) => promise<(array<{"id": string}>, array<unknown>)>,
  // Write batch to storage. `siblingTxHooks` carries settled promises from
  // peer storages (e.g. ClickHouse) that were kicked off in parallel — the
  // primary storage awaits them inside its transaction so a peer failure
  // aborts the commit, preserving cross-storage consistency. Non-primary
  // storages can ignore the hook.
  writeBatch: (
    ~batch: Batch.t,
    ~rawEvents: array<InternalTable.RawEvents.t>,
    ~rollbackTargetCheckpointId: option<Internal.checkpointId>,
    ~isInReorgThreshold: bool,
    ~config: Config.t,
    ~allEntities: array<Internal.entityConfig>,
    ~updatedEffectsCache: array<updatedEffectCache>,
    ~updatedEntities: array<updatedEntity>,
    ~siblingTxHooks: array<promise<option<exn>>>=?,
  ) => promise<unit>,
  // Align this storage to the primary's last-committed checkpoint after a
  // resume — drops rows newer than `checkpointId` from history / checkpoints
  // tables, so a mirror that crashed mid-batch lines up with the primary on
  // restart. The primary itself is the source of truth and does no work.
  alignToCheckpoint: (~checkpointId: Internal.checkpointId) => promise<unit>,
  // Release any long-lived resources (e.g. the postgres connection pool) so
  // short-lived CLI commands like `db-migrate setup` can exit cleanly.
  close: unit => promise<unit>,
}

type storageStatus =
  | Unknown
  | Initializing(promise<unit>)
  | Ready(initialState)

type t = {
  userEntities: array<Internal.entityConfig>,
  allEntities: array<Internal.entityConfig>,
  allEnums: array<Table.enumConfig<Table.enum>>,
  mutable storageStatus: storageStatus,
  // Primary system storage — owns chains, checkpoints, raw events, the
  // canonical envio_info, and per-entity loaders / rollback queries. PG today.
  mutable storage: storage,
  // Peer storages (e.g. ClickHouse) that participate in init validation,
  // writeBatch fan-out, reset, and close alongside `storage`. Empty when no
  // additional backends are configured.
  additionalStorages: array<storage>,
}

exception StorageError({message: string, reason: exn})

let make = (
  ~userEntities,
  // TODO: Should only pass userEnums and create internal config in runtime
  ~allEnums,
  ~storage,
  ~additionalStorages=[],
) => {
  let allEntities = userEntities->Array.concat([InternalTable.EnvioAddresses.entityConfig])
  let allEnums =
    allEnums->Array.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])
  {
    userEntities,
    allEntities,
    allEnums,
    storageStatus: Unknown,
    storage,
    additionalStorages,
  }
}

let allStorages = persistence => [persistence.storage]->Array.concat(persistence.additionalStorages)

let resetAll = persistence =>
  Promise.all(persistence->allStorages->Belt.Array.map(s => s.reset()))->Utils.Promise.ignoreValue

let closeAll = persistence =>
  Promise.all(persistence->allStorages->Belt.Array.map(s => s.close()))->Utils.Promise.ignoreValue

// Per-entity primary: the storage that owns the entity's canonical table for
// load operations. PG wins when the entity opts into both backends; an entity
// that opted out of PG falls back to the first peer storage that owns it (today
// always ClickHouse). With only PG configured this always returns the primary.
let getPrimaryStorageForEntity = (persistence, ~entityConfig: Internal.entityConfig) =>
  if entityConfig.storage.postgres {
    persistence.storage
  } else {
    switch persistence.additionalStorages->Belt.Array.get(0) {
    | Some(s) => s
    | None => persistence.storage
    }
  }

let init = {
  async (persistence, ~chainConfigs, ~envioInfo, ~resetCommand, ~reset=false) => {
    try {
      let shouldRun = switch persistence.storageStatus {
      | Unknown => true
      | Initializing(promise) => {
          await promise
          reset
        }
      | Ready(_) => reset
      }
      if shouldRun {
        let resolveRef = ref(%raw(`null`))
        let promise = Promise.make((resolve, _) => {
          resolveRef := resolve
        })
        persistence.storageStatus = Initializing(promise)
        let storages = persistence->allStorages
        // Skip the existence probe when forcing a reset — we're going to
        // reinitialize regardless. Matches the old single-storage `||`
        // short-circuit and keeps the call count predictable for callers.
        let initializedFlags = reset
          ? []
          : await Promise.all(storages->Belt.Array.map(s => s.isInitialized()))
        let anyInitialized = initializedFlags->Array.some(b => b)
        let allInitialized =
          initializedFlags->Utils.Array.notEmpty && initializedFlags->Array.every(b => b)

        if reset || !anyInitialized {
          Logging.info(`Initializing the indexer storage...`)
          let initialStates = await Promise.all(
            storages->Belt.Array.map(s =>
              s.initialize(
                ~entities=persistence.allEntities,
                ~enums=persistence.allEnums,
                ~chainConfigs,
                ~envioInfo,
              )
            ),
          )
          // Primary is at index 0 — its initialState carries the canonical
          // system data (chains, checkpointId, effect cache).
          let initialState = initialStates->Belt.Array.getUnsafe(0)
          Logging.info(`The indexer storage is ready. Starting indexing!`)
          persistence.storageStatus = Ready(initialState)
        } else if !allInitialized {
          // Mixed state: some storages fresh, some already initialized.
          // Refuse to proceed — would leave them out of sync.
          let initializedNames = []
          let freshNames = []
          storages->Belt.Array.forEachWithIndex((idx, s) =>
            if initializedFlags->Belt.Array.getUnsafe(idx) {
              initializedNames->Array.push(s.name)->ignore
            } else {
              freshNames->Array.push(s.name)->ignore
            }
          )
          JsError.throwWithMessage(
            `Indexer storages are out of sync. Initialized: ${initializedNames->Array.joinUnsafe(
                ", ",
              )}. Uninitialized: ${freshNames->Array.joinUnsafe(
                ", ",
              )}. Run "${resetCommand}" to reinitialize all storages.`,
          )
        } else if (
          // In case of a race condition,
          // we want to set the initial status to Ready only once.
          switch persistence.storageStatus {
          | Initializing(_) => true
          | _ => false
          }
        ) {
          Logging.info(`Found existing indexer storage. Resuming indexing state...`)
          let resumedStates = await Promise.all(
            storages->Belt.Array.map(s => s.resumeInitialState()),
          )
          // Each storage stores its own envio_info; compat-check every one
          // against the running config. When more than one storage is
          // configured we prefix the storage name on each bullet so the user
          // can see which backend disagrees; with a single storage the prefix
          // is noise.
          let allChangedPaths = []
          let shouldLabel = storages->Array.length > 1
          storages->Belt.Array.forEachWithIndex((idx, s) => {
            let resumed = resumedStates->Belt.Array.getUnsafe(idx)
            let storageChanges = switch resumed.envioInfo {
            | None => ["envio info is missing — storage initialized by an older envio"]
            | Some(stored) => Config.diffPaths(~stored, ~current=envioInfo)
            }
            storageChanges->Array.forEach(path =>
              allChangedPaths
              ->Array.push(shouldLabel ? `${s.name}: ${path}` : path)
              ->ignore
            )
          })
          Config.throwIfIncompatible(allChangedPaths, ~resetCommand)
          let initialState = resumedStates->Belt.Array.getUnsafe(0)

          // Align mirror storages to the primary's committed checkpoint so a
          // mid-batch crash on a mirror doesn't leave it ahead of PG.
          if persistence.additionalStorages->Utils.Array.notEmpty {
            await Promise.all(
              persistence.additionalStorages->Belt.Array.map(s =>
                s.alignToCheckpoint(~checkpointId=initialState.checkpointId)
              ),
            )->Utils.Promise.ignoreValue
          }
          persistence.storageStatus = Ready(initialState)
          let progress = Dict.make()
          initialState.chains->Array.forEach(c => {
            progress->Utils.Dict.setByInt(c.id, c.progressBlockNumber)
          })
          Logging.info({
            "msg": `Successfully resumed indexing state! Continuing from the last checkpoint.`,
            "progress": progress,
          })
        }
        resolveRef.contents()
      }
    } catch {
    | exn => exn->ErrorHandling.mkLogAndRaise(~msg=`Failed to initialize the indexer storage.`)
    }
  }
}

let getInitializedStorageOrThrow = persistence => {
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    JsError.throwWithMessage(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready(_) => persistence.storage
  }
}

let getInitializedState = persistence => {
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    JsError.throwWithMessage(`Failed to access the initial state. The Persistence layer is not initialized.`)
  | Ready(initialState) => initialState
  }
}

let writeBatch = (
  persistence,
  ~batch,
  ~config,
  ~inMemoryStore: InMemoryStore.t,
  ~isInReorgThreshold,
) =>
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    JsError.throwWithMessage(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) =>
    let updatedEntities = persistence.allEntities->Belt.Array.keepMap(entityConfig => {
      let updates =
        inMemoryStore
        ->InMemoryStore.getInMemTable(~entityConfig)
        ->InMemoryTable.Entity.updates
      if updates->Utils.Array.isEmpty {
        None
      } else {
        Some({entityConfig, updates})
      }
    })
    let rawEvents = inMemoryStore.rawEvents->InMemoryTable.values
    let rollbackTargetCheckpointId = inMemoryStore.rollbackTargetCheckpointId
    let updatedEffectsCache = {
      let acc = []
      inMemoryStore.effects->Utils.Dict.forEach(inMemTable => {
        let {idsToStore, dict, effect, invalidationsCount} = inMemTable
        switch idsToStore {
        | [] => ()
        | ids =>
          let items = Belt.Array.makeUninitializedUnsafe(ids->Belt.Array.length)
          ids->Belt.Array.forEachWithIndex((index, id) => {
            items->Array.setUnsafe(
              index,
              (
                {
                  id,
                  output: dict->Dict.getUnsafe(id),
                }: Internal.effectCacheItem
              ),
            )
          })
          let effectName = effect.name
          let effectCacheRecord = switch cache->Utils.Dict.dangerouslyGetNonOption(effectName) {
          | Some(c) => c
          | None =>
            let c = {effectName, count: 0}
            cache->Dict.set(effectName, c)
            c
          }
          let shouldInitialize = effectCacheRecord.count === 0
          effectCacheRecord.count =
            effectCacheRecord.count + items->Array.length - invalidationsCount
          Prometheus.EffectCacheCount.set(~count=effectCacheRecord.count, ~effectName)
          acc->Array.push({effect, items, shouldInitialize})->ignore
        }
      })
      acc
    }
    // Kick off mirror writes first so the primary's transaction can await
    // their settlement before committing. A mirror failure throws inside the
    // primary's tx, rolling back the PG side and preserving cross-storage
    // consistency.
    let siblingTxHooks = persistence.additionalStorages->Belt.Array.map(storage => {
      storage.writeBatch(
        ~batch,
        ~rawEvents,
        ~rollbackTargetCheckpointId,
        ~isInReorgThreshold,
        ~config,
        ~allEntities=persistence.allEntities,
        ~updatedEntities,
        ~updatedEffectsCache,
      )
      ->Promise.thenResolve(_ => None)
      ->Utils.Promise.catchResolve(exn => Some(exn))
    })
    persistence.storage.writeBatch(
      ~batch,
      ~rawEvents,
      ~rollbackTargetCheckpointId,
      ~isInReorgThreshold,
      ~config,
      ~allEntities=persistence.allEntities,
      ~updatedEntities,
      ~updatedEffectsCache,
      ~siblingTxHooks,
    )
  }

let prepareRollbackDiff = async (
  persistence: t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
) => {
  let inMemStore = InMemoryStore.make(
    ~entities=persistence.allEntities,
    ~rollbackTargetCheckpointId,
  )

  let deletedEntities = Dict.make()
  let setEntities = Dict.make()

  let _ = await persistence.allEntities
  ->Belt.Array.map(async entityConfig => {
    let entityTable = inMemStore->InMemoryStore.getInMemTable(~entityConfig)

    let (removedIdsResult, restoredEntitiesResult) = await persistence.storage.getRollbackData(
      ~entityConfig,
      ~rollbackTargetCheckpointId,
    )

    // Process removed IDs
    removedIdsResult->Array.forEach(data => {
      deletedEntities->Utils.Dict.push(entityConfig.name, data["id"])
      entityTable->InMemoryTable.Entity.set(
        Delete({
          entityId: data["id"],
          checkpointId: rollbackDiffCheckpointId,
        }),
        ~shouldSaveHistory=false,
        ~containsRollbackDiffChange=true,
      )
    })

    let restoredEntities = restoredEntitiesResult->S.parseOrThrow(entityConfig.rowsSchema)

    // Process restored entities
    restoredEntities->Belt.Array.forEach((entity: Internal.entity) => {
      setEntities->Utils.Dict.push(entityConfig.name, entity.id)
      entityTable->InMemoryTable.Entity.set(
        Set({
          entityId: entity.id,
          checkpointId: rollbackDiffCheckpointId,
          entity,
        }),
        ~shouldSaveHistory=false,
        ~containsRollbackDiffChange=true,
      )
    })
  })
  ->Promise.all

  {
    "inMemStore": inMemStore,
    "deletedEntities": deletedEntities,
    "setEntities": setEntities,
  }
}
