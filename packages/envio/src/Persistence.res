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

type updatedEffectCache = {
  effect: Internal.effect,
  items: array<Internal.effectCacheItem>,
  shouldInitialize: bool,
}

type rollback = {
  targetCheckpointId: Internal.checkpointId,
  diffCheckpointId: Internal.checkpointId,
  // Last valid block per chain affected by the rollback. Read by
  // `RollbackCommit.fire` once the diff is durably written.
  progressBlockNumberByChainId: dict<int>,
}

type updatedEntity = {
  entityConfig: Internal.entityConfig,
  changes: array<Change.t<Internal.entity>>,
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
  // Returns rows matching the filter.
  // Field values are serialized and rows parsed with the table's field schemas.
  @raises("StorageError")
  loadOrThrow: (~filter: EntityFilter.t, ~table: Table.table) => promise<array<unknown>>,
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
  // Removed rows carry "chainId" for isolated entities so the rollback diff
  // can route them to the right per-chain in-memory table.
  getRollbackData: (
    ~entityConfig: Internal.entityConfig,
    ~rollbackTargetCheckpointId: Internal.checkpointId,
  ) => promise<(array<{"id": string, "chainId": option<int>}>, array<unknown>)>,
  // Write batch to storage
  writeBatch: (
    ~batch: Batch.t,
    ~rollback: option<rollback>,
    ~isInReorgThreshold: bool,
    ~config: Config.t,
    ~allEntities: array<Internal.entityConfig>,
    ~updatedEffectsCache: array<updatedEffectCache>,
    ~updatedEntities: array<updatedEntity>,
    // Chain metadata stale since the last write, persisted in the same
    // transaction so it never races the batch write.
    ~chainMetaData: option<dict<InternalTable.Chains.metaFields>>,
  ) => promise<unit>,
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
  mutable storage: storage,
}

exception StorageError({message: string, reason: exn})

let make = (
  ~userEntities,
  // TODO: Should only pass userEnums and create internal config in runtime
  ~allEnums,
  ~storage,
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
  }
}

let init = {
  async (persistence, ~chainConfigs, ~envioInfo, ~resetCommand, ~runCommand, ~reset=false) => {
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
            ~envioInfo,
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
          // Compat-check the running config against what was stored on the
          // last successful initialize. None means the schema pre-dates
          // envio_info (or the row was wiped out-of-band) and we can't
          // compare — treat it as a version mismatch.
          let changedPaths = switch initialState.envioInfo {
          | None => ["envio info is missing — storage initialized by an older envio"]
          | Some(stored) => Config.diffPaths(~stored, ~current=envioInfo)
          }
          // `storage.clickhouse` is serialized as a plain bool by the
          // public config (see Rust `StorageConfig`), so probe for
          // `Boolean(true)`, not an object.
          let hasClickhouse = switch envioInfo {
          | Object(d) =>
            switch d->Dict.get("storage") {
            | Some(Object(s)) =>
              switch s->Dict.get("clickhouse") {
              | Some(Boolean(true)) => true
              | _ => false
              }
            | _ => false
            }
          | _ => false
          }
          Config.throwIfIncompatible(changedPaths, ~resetCommand, ~runCommand, ~hasClickhouse)
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
