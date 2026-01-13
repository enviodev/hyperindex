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
  numEventsProcessed: int,
  firstEventBlockNumber: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  dynamicContracts: array<Internal.indexingContract>,
  sourceBlockNumber: int,
}

type initialState = {
  cleanRun: bool,
  cache: dict<effectCacheRecord>,
  chains: array<initialChainState>,
  checkpointId: Internal.checkpointId,
  // Needed to keep reorg detection logic between restarts
  reorgCheckpoints: array<Internal.reorgCheckpoint>,
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
  // Should return true if we already have persisted data
  // and we can skip initialization
  isInitialized: unit => promise<bool>,
  // Should initialize the storage so we can start interacting with it
  // Eg create connection, schema, tables, etc.
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Table.enumConfig<Table.enum>>=?,
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
  @raises("StorageError")
  setOrThrow: 'item. (
    ~items: array<'item>,
    ~table: Table.table,
    ~itemSchema: S.t<'item>,
  ) => promise<unit>,
  @raises("StorageError")
  setEffectCacheOrThrow: (
    ~effect: Internal.effect,
    ~items: array<Internal.effectCacheItem>,
    ~initialize: bool,
  ) => promise<unit>,
  // This is to download cache from the database to .envio/cache
  dumpEffectCache: unit => promise<unit>,
  // Execute raw SQL query
  executeUnsafe: string => promise<unknown>,
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
  ) => promise<array<{"id": Internal.checkpointId}>>,
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
  // Write batch to storage
  writeBatch: (
    ~batch: Batch.t,
    ~rawEvents: array<InternalTable.RawEvents.t>,
    ~rollbackTargetCheckpointId: option<Internal.checkpointId>,
    ~isInReorgThreshold: bool,
    ~config: Config.t,
    ~allEntities: array<Internal.entityConfig>,
    ~updatedEffectsCache: array<updatedEffectCache>,
    ~updatedEntities: array<updatedEntity>,
  ) => promise<unit>,
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
  mutable storage: storage,
}

exception StorageError({message: string, reason: exn})

let make = (
  ~userEntities,
  // TODO: Should only pass userEnums and create internal config in runtime
  ~allEnums,
  ~storage,
) => {
  let allEntities = userEntities->Js.Array2.concat([InternalTable.DynamicContractRegistry.config])
  let allEnums =
    allEnums->Js.Array2.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])
  {
    userEntities,
    allEntities,
    allEnums,
    storageStatus: Unknown,
    storage,
  }
}

let init = {
  async (persistence, ~chainConfigs, ~reset=false) => {
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
        if reset || !(await persistence.storage.isInitialized()) {
          Logging.info(`Initializing the indexer storage...`)
          let initialState = await persistence.storage.initialize(
            ~entities=persistence.allEntities,
            ~enums=persistence.allEnums,
            ~chainConfigs,
          )
          Logging.info(`The indexer storage is ready. Starting indexing!`)
          persistence.storageStatus = Ready(initialState)
        } else if (
          // In case of a race condition,
          // we want to set the initial status to Ready only once.
          switch persistence.storageStatus {
          | Initializing(_) => true
          | _ => false
          }
        ) {
          Logging.info(`Found existing indexer storage. Resuming indexing state...`)
          let initialState = await persistence.storage.resumeInitialState()
          persistence.storageStatus = Ready(initialState)
          let progress = Js.Dict.empty()
          initialState.chains->Js.Array2.forEach(c => {
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
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(~msg=`EE800: Failed to initialize the indexer storage.`)
    }
  }
}

let getInitializedStorageOrThrow = persistence => {
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    Js.Exn.raiseError(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready(_) => persistence.storage
  }
}

let getInitializedState = persistence => {
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    Js.Exn.raiseError(`Failed to access the initial state. The Persistence layer is not initialized.`)
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
    Js.Exn.raiseError(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) =>
    let updatedEntities = persistence.allEntities->Belt.Array.keepMapU(entityConfig => {
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
    persistence.storage.writeBatch(
      ~batch,
      ~rawEvents=inMemoryStore.rawEvents->InMemoryTable.values,
      ~rollbackTargetCheckpointId=inMemoryStore.rollbackTargetCheckpointId,
      ~isInReorgThreshold,
      ~config,
      ~allEntities=persistence.allEntities,
      ~updatedEntities,
      ~updatedEffectsCache={
        inMemoryStore.effects
        ->Js.Dict.keys
        ->Belt.Array.keepMapU(effectName => {
          let inMemTable = inMemoryStore.effects->Js.Dict.unsafeGet(effectName)
          let {idsToStore, dict, effect, invalidationsCount} = inMemTable
          switch idsToStore {
          | [] => None
          | ids => {
              let items = Belt.Array.makeUninitializedUnsafe(ids->Belt.Array.length)
              ids->Belt.Array.forEachWithIndex((index, id) => {
                items->Js.Array2.unsafe_set(
                  index,
                  (
                    {
                      id,
                      output: dict->Js.Dict.unsafeGet(id),
                    }: Internal.effectCacheItem
                  ),
                )
              })
              Some({
                let effectName = effect.name
                let effectCacheRecord = switch cache->Utils.Dict.dangerouslyGetNonOption(
                  effectName,
                ) {
                | Some(c) => c
                | None => {
                    let c = {effectName, count: 0}
                    cache->Js.Dict.set(effectName, c)
                    c
                  }
                }
                let shouldInitialize = effectCacheRecord.count === 0
                effectCacheRecord.count =
                  effectCacheRecord.count + items->Js.Array2.length - invalidationsCount
                Prometheus.EffectCacheCount.set(~count=effectCacheRecord.count, ~effectName)
                {effect, items, shouldInitialize}
              })
            }
          }
        })
      },
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

  let deletedEntities = Js.Dict.empty()
  let setEntities = Js.Dict.empty()

  let _ =
    await persistence.allEntities
    ->Belt.Array.map(async entityConfig => {
      let entityTable = inMemStore->InMemoryStore.getInMemTable(~entityConfig)

      let (removedIdsResult, restoredEntitiesResult) = await persistence.storage.getRollbackData(
        ~entityConfig,
        ~rollbackTargetCheckpointId,
      )

      // Process removed IDs
      removedIdsResult->Js.Array2.forEach(data => {
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
