// A module for the persistence layer
// This is currently in a WIP state
// but in the future we should make all DB and in-memory state
// interactions to this layer with DI and easy for testing.
// Currently there are quite many code spread across
// DbFunctions, Db, Migrations, InMemoryStore modules which use codegen code directly.

// The type reflects an cache table in the db
// It might be present even if the effect is not used in the application.
// `initialState.cache` is keyed by `tableName` (the full cache address), so a
// cross-chain and a chain-scoped cache for the same effect are tracked
// independently.
type effectCacheRecord = {
  effectName: string,
  scope: Internal.chainScope,
  tableName: string,
  // Number of rows in the table
  mutable count: int,
}

type initialChainState = {
  id: ChainId.t,
  startBlock: int,
  endBlock: option<int>,
  maxReorgDepth: int,
  progressBlockNumber: int,
  numEventsProcessed: float,
  firstEventBlockNumber: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  // Every address the chain indexes, columnar — config-declared and dynamically
  // registered alike. The chain's address store seeds straight from it.
  addressRows: AddressRows.seedRows,
  sourceBlockNumber: int,
}

type initialState = {
  cleanRun: bool,
  // On a resume this is what the database holds, not what the config would
  // derive — the ids must never reshuffle under stored rows.
  contractMapping: ContractMapping.t,
  // Public config snapshot, restored with the address rows. None when
  // envio_info or envio_contracts is missing.
  envioInfo: option<JSON.t>,
  cache: dict<effectCacheRecord>,
  chains: array<initialChainState>,
  checkpointId: Internal.checkpointId,
  // Needed to keep reorg detection logic between restarts
  reorgCheckpoints: array<Internal.reorgCheckpoint>,
}

// Carries the already-resolved cache address (`table`) rather than an effect +
// scope: the scope is contextual (resolved per call from the handler's chain),
// so the write layer only needs the concrete table it targets.
type updatedEffectCache = {
  table: Table.table,
  itemSchema: S.t<Internal.effectCacheItem>,
  items: array<Internal.effectCacheItem>,
  shouldInitialize: bool,
}

type rollback = {
  targetCheckpointId: Internal.checkpointId,
  diffCheckpointId: Internal.checkpointId,
  // The address registrations the rollback dropped, as the chains' address
  // stores resolved them. Deleted by primary key in the same transaction.
  rolledBackAddresses: array<AddressRows.key>,
  // Last valid block per chain affected by the rollback. Read by
  // `RollbackCommit.fire` once the diff is durably written.
  progressBlockNumberByChainId: dict<int>,
}

// One flush group: the changes an entity accumulated within a single chain
// scope. A per-chain entity contributes one group per chain, and the scope is
// what stamps the chain id onto the rows — it's never re-derived downstream.
type updatedEntity = {
  entityConfig: Internal.entityConfig,
  scope: Internal.chainScope,
  changes: array<Change.t<Internal.entity>>,
}

// An id the rollback must delete, together with the scope its row lives in.
type rollbackRemoval = {
  entityId: EntityId.t,
  scope: Internal.chainScope,
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
    ~contractMapping: ContractMapping.t,
    ~envioInfo: JSON.t,
  ) => promise<initialState>,
  resumeInitialState: unit => promise<initialState>,
  // Returns rows matching the filter.
  // Field values are serialized and rows parsed with the table's field schemas.
  @raises("StorageError")
  loadOrThrow: (~filter: EntityFilter.t, ~table: Table.table) => promise<array<unknown>>,
  // Creates whatever indexes the filters need and aren't there yet, resolving
  // once they're queryable. Best-effort: it resolves even when a build fails,
  // leaving the query to run unindexed rather than failing the handler.
  ensureQueryIndexes: (~table: Table.table, ~filters: array<EntityFilter.t>) => promise<unit>,
  // Creates every schema-defined index still missing, without touching
  // `ready_at`. For a resumed indexer that is already ready and so never runs
  // `finalizeBackfill`: an index dropped or invalidated while it was down would
  // otherwise never be rebuilt. Best-effort, and safe to run with indexing live.
  ensureSchemaIndexes: (~entities: array<Internal.entityConfig>) => promise<unit>,
  // Creates every schema-defined index still missing, then stamps `ready_at` on
  // the given chains. Called once, when backfill completes. The indexes are
  // committed one at a time so a failure part way through doesn't undo the ones
  // already built; `ready_at` is only written once they all verify, and all
  // chains are stamped together.
  finalizeBackfill: (
    ~entities: array<Internal.entityConfig>,
    ~chainIds: array<ChainId.t>,
    ~readyAt: Date.t,
  ) => promise<unit>,
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
    ~chainIdColumn: option<string>,
    ~safeCheckpointId: Internal.checkpointId,
  ) => promise<unit>,
  // Get rollback target checkpoint
  getRollbackTargetCheckpoint: (
    ~reorgChainId: ChainId.t,
    ~lastKnownValidBlockNumber: int,
  ) => promise<option<Internal.checkpointId>>,
  // Get rollback progress diff
  getRollbackProgressDiff: (
    ~rollbackTargetCheckpointId: Internal.checkpointId,
  ) => promise<
    array<{
      "chain_id": ChainId.t,
      "events_processed_diff": string,
      "new_progress_block_number": int,
    }>,
  >,
  // Rollback data for an entity, as decoded entities rather than storage rows:
  // only the storage knows how it encoded them, so each one decodes its own
  // before handing them back.
  getRollbackData: (
    ~entityConfig: Internal.entityConfig,
    ~rollbackTargetCheckpointId: Internal.checkpointId,
  ) => promise<(array<rollbackRemoval>, array<Internal.entity>)>,
  // Write batch to storage
  writeBatch: (
    ~batch: Batch.t,
    ~rollback: option<rollback>,
    ~isInReorgThreshold: bool,
    ~config: Config.t,
    ~allEntities: array<Internal.entityConfig>,
    ~updatedEffectsCache: array<updatedEffectCache>,
    ~updatedEntities: array<updatedEntity>,
    // Addresses this batch registered, with the checkpoint that covers them.
    ~registeredAddresses: array<AddressRows.staged>,
    // Chain metadata stale since the last write, persisted in the same
    // transaction so it never races the batch write.
    ~chainMetaData: option<dict<InternalTable.Chains.metaFields>>,
    // Reports each underlying storage's write duration (e.g. postgres and a
    // configured sink separately), accumulated into the write metrics.
    ~onWrite: (~storage: string, ~timeSeconds: float) => unit,
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
  let allEntities = userEntities
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
  async (
    persistence,
    ~chainConfigs,
    ~contractMapping,
    ~envioInfo,
    ~resetCommand,
    ~runCommand,
    ~reset=false,
  ) => {
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
            ~contractMapping,
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
          let changedPaths = switch initialState.envioInfo {
          | None => ["storage was initialized by an older envio version"]
          | Some(stored) => Config.diffPaths(~stored, ~current=envioInfo)
          }
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
          if !(initialState.contractMapping->ContractMapping.isEqual(contractMapping)) {
            Config.throwIfIncompatible(["contracts"], ~resetCommand, ~runCommand, ~hasClickhouse)
          }
          persistence.storageStatus = Ready(initialState)
          let progress = Dict.make()
          initialState.chains->Array.forEach(c => {
            progress->ChainId.Dict.set(c.id, c.progressBlockNumber)
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
