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

// A chain's committed position, as the barrier reads it. Judged rather than
// stamped: `progress_block` and `source_block` are written as one group by the
// batch write, so this is always a consistent pair from the last commit.
type chainProgress = {
  id: ChainId.t,
  progressBlockNumber: int,
  sourceBlockNumber: int,
  endBlock: option<int>,
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
  // Where each chain's checkpoint sequence stands in the database.
  checkpointFrontier: Frontier.t,
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
  // The id each chain's diff rows are stamped with: the first after what that
  // chain has committed.
  diffFrontier: Frontier.t,
  // The same ids as checkpoint rows, for a sink that resolves current state
  // through them. Postgres writes the diff to the entity table and ignores these.
  diffCheckpoints: array<InternalTable.Checkpoints.diffCheckpoint>,
  // How far back the deletes reach on each chain, travelling with the diff so
  // the write leaves an untouched sibling's rows alone.
  floors: RollbackFloors.t,
  // The address registrations the rollback dropped, as the chains' address
  // stores resolved them. Deleted by primary key in the same transaction.
  rolledBackAddresses: array<AddressRows.key>,
  // Where the rollback left every chain it moved. Written with the diff rather
  // than waiting for a batch of those chains' own: the batch that carries the
  // diff can belong to a chain the rollback never touched, and a chain whose
  // stored progress outlived the checkpoints backing it would resume past
  // blocks it never re-indexed. Also what `RollbackCommit.fire` reports once
  // the diff is durably written.
  progressedChains: array<InternalTable.Chains.progressedChain>,
}

// Where a write leaves each chain's sequence. A rollback's diff rows sit on
// chains the batch may not have progressed at all, so the write reaches them too.
let writtenFrontier = (~batch: Batch.t, ~rollback: option<rollback>) =>
  switch rollback {
  | Some({diffFrontier}) => Frontier.mergeMax(batch->Batch.checkpointFrontier, diffFrontier)
  | None => batch->Batch.checkpointFrontier
  }

// One flush group: the changes an entity accumulated within a single chain
// scope. A per-chain entity contributes one group per chain, and the scope is
// what stamps the chain id onto the rows — it's never re-derived downstream.
type updatedEntity = {
  entityConfig: Internal.entityConfig,
  scope: Internal.chainScope,
  changes: array<Change.t<Internal.entity>>,
  shouldSaveHistory: bool,
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
  // `throwIfIncompatible` gets what the storage holds before any sink is
  // resumed, so a config the stored one rules out is reported as such rather
  // than as the sink tripping over tables it never created.
  resumeInitialState: (
    ~entities: array<Internal.entityConfig>,
    ~throwIfIncompatible: (
      ~storedEnvioInfo: option<JSON.t>,
      ~storedContractMapping: ContractMapping.t,
    ) => unit,
  ) => promise<initialState>,
  // Returns rows matching the filter.
  // Field values are serialized and rows parsed with the table's field schemas.
  @raises("StorageError")
  loadOrThrow: (~filter: EntityFilter.t, ~table: Table.table) => promise<array<unknown>>,
  // Creates whatever indexes the filters need and aren't there yet, resolving
  // once they're queryable. Best-effort: it resolves even when a build fails,
  // leaving the query to run unindexed rather than failing the handler.
  ensureQueryIndexes: (~table: Table.table, ~filters: array<EntityFilter.t>) => promise<unit>,
  // How far every chain in the schema has committed, the ones other
  // `envio start --chain` processes drive included. Read to decide whether any
  // chain is still backfilling, and so whether the schema's indexes are owed.
  readChainProgress: unit => promise<array<chainProgress>>,
  // Creates every schema-defined index still missing, then stamps `ready_at` on
  // every chain. Called once every chain has finished backfill. The indexes are
  // committed one at a time so a failure part way through doesn't undo the ones
  // already built; `ready_at` is only written once they all verify.
  finalizeBackfill: (
    ~entities: array<Internal.entityConfig>,
    ~readyAt: Date.t,
  ) => promise<unit>,
  // This is to download cache from the database to .envio/cache
  dumpEffectCache: unit => promise<unit>,
  reset: unit => promise<unit>,
  // Update chain metadata
  setChainMeta: dict<InternalTable.Chains.metaFields> => promise<unknown>,
  // Prune old checkpoints
  pruneStaleCheckpoints: (
    ~safeCheckpoints: CheckpointSequence.checkpointBoundsByChain,
  ) => promise<unit>,
  // Prune stale entity history
  pruneStaleEntityHistory: (
    ~entityName: string,
    ~entityIndex: int,
    ~chainIdColumn: option<string>,
    ~safeCheckpoints: CheckpointSequence.checkpointBoundsByChain,
  ) => promise<unit>,
  // Get rollback target checkpoint
  getRollbackTargetCheckpoint: (
    ~reorgChainId: ChainId.t,
    ~lastKnownValidBlockNumber: int,
  ) => promise<option<Internal.checkpointId>>,
  // Get rollback progress diff
  getRollbackProgressDiff: (
    ~floors: RollbackFloors.t,
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
    ~floors: RollbackFloors.t,
  ) => promise<(array<rollbackRemoval>, array<Internal.entity>)>,
  // Write batch to storage
  writeBatch: (
    ~batch: Batch.t,
    ~rollback: option<rollback>,
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

// Keeps only what the chains this run drives own. Unconditional, because
// "resume the chains I was given" holds in every mode — with the full set it is
// a no-op, and a config that genuinely disagrees with the database was already
// rejected by `throwIfResumeIncompatible`, which compares the stored chain list.
//
// The checkpoint frontier is left whole: under the per-chain sequence a subset
// run requires, a chain only ever reads its own position out of it.
%%private(
  let narrowToChains = (initialState: initialState, ~chainConfigs: array<Config.chain>) => {
    let isActive = Dict.make()
    chainConfigs->Array.forEach(chain => isActive->ChainId.Dict.set(chain.id, true))
    let has = chainId => isActive->ChainId.Dict.dangerouslyGetNonOption(chainId)->Option.isSome
    {
      ...initialState,
      chains: initialState.chains->Array.filter(chain => has(chain.id)),
      reorgCheckpoints: initialState.reorgCheckpoints->Array.filter(checkpoint =>
        has(checkpoint.chainId)
      ),
    }
  }
)

let init = {
  async (
    persistence,
    ~chainConfigs: array<Config.chain>,
    ~contractMapping,
    ~envioInfo,
    ~resetCommand,
    ~runCommand,
    ~reset=false,
    ~lowercaseAddresses=false,
    // `envio start --chain` needs the schema to exist already: initializing
    // under it would create rows for this process's chains only, leaving the
    // ones it skipped with no state for their own processes to resume.
    ~requireInitialized=false,
    ~startBlockRetry=StartBlockResolver.UntilItAnswers,
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
          if requireInitialized {
            JsError.throwWithMessage(
              "`envio start --chain` needs a database that already holds every chain. Run `envio local db-migrate up` once with the full config, then start a process per chain.",
            )
          }
          Logging.info(`Initializing the indexer storage...`)
          // Only runs once per schema (this branch is the "first deploy or
          // reset" gate), which is exactly when a `latest` start block must be
          // resolved: every later resume reads `envio_chains.start_block` back
          // verbatim instead of re-running this.
          let chainConfigs = await chainConfigs->StartBlockResolver.resolveAllOrThrow(
            ~lowercaseAddresses,
            ~retry=startBlockRetry,
          )
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
          let initialState = await persistence.storage.resumeInitialState(
            ~entities=persistence.allEntities,
            ~throwIfIncompatible=(~storedEnvioInfo, ~storedContractMapping) =>
              Config.throwIfResumeIncompatible(
                ~storedEnvioInfo,
                ~storedContractMapping,
                ~envioInfo,
                ~contractMapping,
                ~resetCommand,
                ~runCommand,
              ),
          )
          let initialState = initialState->narrowToChains(~chainConfigs)
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
