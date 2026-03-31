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

type rollbackEntityDiff = {
  entityConfig: Internal.entityConfig,
  removedIds: array<string>,
  restoredEntities: array<Internal.entity>,
}

type rollbackDiff = {
  rollbackTargetCheckpointId: Internal.checkpointId,
  rollbackDiffCheckpointId: Internal.checkpointId,
  entityChanges: array<rollbackEntityDiff>,
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

type effectCacheWriteData = {
  effect: Internal.effect,
  items: array<Internal.effectCacheItem>,
  invalidationsCount: int,
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

type writeArgs = {
  batch: Batch.t,
  config: Config.t,
  isInReorgThreshold: bool,
  updatedEntities: array<updatedEntity>,
  rawEvents: array<InternalTable.RawEvents.t>,
  effectCacheWriteData: array<effectCacheWriteData>,
  rollbackTargetCheckpointId: option<Internal.checkpointId>,
  onWriteComplete: bigint => unit,
}

type t = {
  userEntities: array<Internal.entityConfig>,
  allEntities: array<Internal.entityConfig>,
  allEnums: array<Table.enumConfig<Table.enum>>,
  mutable storageStatus: storageStatus,
  mutable storage: storage,
  mutable writePromise: option<promise<unit>>,
  mutable pendingWrite: option<writeArgs>,
  mutable writtenCheckpointId: bigint,
}

exception StorageError({message: string, reason: exn})

let make = (
  ~userEntities,
  // TODO: Should only pass userEnums and create internal config in runtime
  ~allEnums,
  ~storage,
) => {
  let allEntities =
    userEntities->Js.Array2.concat([InternalTable.DynamicContractRegistry.entityConfig])
  let allEnums =
    allEnums->Js.Array2.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])
  {
    userEntities,
    allEntities,
    allEnums,
    storageStatus: Unknown,
    storage,
    writePromise: None,
    pendingWrite: None,
    writtenCheckpointId: 0n,
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
          persistence.writtenCheckpointId = initialState.checkpointId
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
          persistence.writtenCheckpointId = initialState.checkpointId
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
    | exn => exn->ErrorHandling.mkLogAndRaise(~msg=`Failed to initialize the indexer storage.`)
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
  ~isInReorgThreshold,
  ~updatedEntities,
  ~rawEvents,
  ~effectCacheWriteData: array<effectCacheWriteData>,
  ~rollbackTargetCheckpointId,
) =>
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    Js.Exn.raiseError(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) =>
    persistence.storage.writeBatch(
      ~batch,
      ~rawEvents,
      ~rollbackTargetCheckpointId,
      ~isInReorgThreshold,
      ~config,
      ~allEntities=persistence.allEntities,
      ~updatedEntities,
      ~updatedEffectsCache={
        effectCacheWriteData->Belt.Array.mapU(({effect, items, invalidationsCount}) => {
          let effectName = effect.name
          let effectCacheRecord = switch cache->Utils.Dict.dangerouslyGetNonOption(effectName) {
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
      },
    )
  }

let prepareRollbackDiff = async (
  persistence: t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
): rollbackDiff => {
  let entityChanges =
    await persistence.allEntities
    ->Belt.Array.map(async entityConfig => {
      let (removedIdsResult, restoredEntitiesResult) = await persistence.storage.getRollbackData(
        ~entityConfig,
        ~rollbackTargetCheckpointId,
      )

      let removedIds = removedIdsResult->Js.Array2.map(data => data["id"])
      let restoredEntities = restoredEntitiesResult->S.parseOrThrow(entityConfig.rowsSchema)

      ({entityConfig, removedIds, restoredEntities}: rollbackEntityDiff)
    })
    ->Promise.all

  {rollbackTargetCheckpointId, rollbackDiffCheckpointId, entityChanges}
}

let isWriting = persistence => persistence.writePromise !== None

let getLastCheckpointId = (batch: Batch.t) =>
  switch batch.checkpointIds->Utils.Array.last {
  | Some(id) => id
  | None => Js.Exn.raiseError("Unexpected empty batch: no checkpoint IDs")
  }

let rec executeWrite = persistence => {
  switch persistence.pendingWrite {
  | None => ()
  | Some({
      batch,
      config,
      isInReorgThreshold,
      updatedEntities,
      rawEvents,
      effectCacheWriteData,
      rollbackTargetCheckpointId,
      onWriteComplete,
    }) =>
    persistence.pendingWrite = None

    let logger = Logging.getLogger()
    let timeRef = Hrtime.makeTimer()

    let promise = (
      async () => {
        try {
          await persistence->writeBatch(
            ~batch,
            ~config,
            ~isInReorgThreshold,
            ~updatedEntities,
            ~rawEvents,
            ~effectCacheWriteData,
            ~rollbackTargetCheckpointId,
          )

          persistence.writtenCheckpointId = batch->getLastCheckpointId

          let dbWriteDuration = timeRef->Hrtime.timeSince->Hrtime.toSecondsFloat
          logger->Logging.childTrace({
            "msg": "Background write completed",
            "write_time_elapsed": dbWriteDuration,
          })
          Prometheus.ProcessingBatch.setDbWriteDuration(~dbWriteDuration)

          onWriteComplete(persistence.writtenCheckpointId)

          persistence.writePromise = None

          // If a new write was queued during this write, start it
          executeWrite(persistence)
        } catch {
        | StorageError({message, reason}) =>
          persistence.writePromise = None
          reason->ErrorHandling.mkLogAndRaise(~msg=message, ~logger)
        | exn =>
          persistence.writePromise = None
          exn->ErrorHandling.mkLogAndRaise(~msg="Failed writing batch to database", ~logger)
        }
      }
    )()

    persistence.writePromise = Some(promise)
  }
}

// Queue a write. If not currently writing, starts immediately.
let startWrite = (persistence, ~writeArgs) => {
  persistence.pendingWrite = Some(writeArgs)
  if !isWriting(persistence) {
    executeWrite(persistence)
  }
}

// Await the current write and any pending writes.
@raises("WriteError")
let awaitCurrentWrite = async persistence => {
  let continue = ref(true)
  while continue.contents {
    switch persistence.writePromise {
    | Some(promise) => await promise
    | None => continue := false
    }
  }
}

// Flush all pending and in-progress writes.
@raises("WriteError")
let flushWrites = async persistence => {
  // Start any pending write that hasn't begun yet
  if !isWriting(persistence) {
    executeWrite(persistence)
  }
  await awaitCurrentWrite(persistence)
}
