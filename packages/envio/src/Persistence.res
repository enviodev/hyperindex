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

// Where a chain stands, as its row in the storage holds it.
type chainProgress = {
  id: ChainId.t,
  startBlock: int,
  endBlock: option<int>,
  maxReorgDepth: int,
  progressBlockNumber: int,
  progressBlockTime: option<int>,
  numEventsProcessed: float,
  firstEventBlockNumber: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  sourceBlockNumber: int,
}

type initialChainState = {
  ...chainProgress,
  // Every address the chain indexes, columnar — config-declared and dynamically
  // registered alike. The chain's address store seeds straight from it.
  addressRows: AddressRows.seedRows,
}

let withAddressRows = (progress: chainProgress, addressRows): initialChainState => {
  id: progress.id,
  startBlock: progress.startBlock,
  endBlock: progress.endBlock,
  maxReorgDepth: progress.maxReorgDepth,
  progressBlockNumber: progress.progressBlockNumber,
  progressBlockTime: progress.progressBlockTime,
  numEventsProcessed: progress.numEventsProcessed,
  firstEventBlockNumber: progress.firstEventBlockNumber,
  timestampCaughtUpToHeadOrEndblock: progress.timestampCaughtUpToHeadOrEndblock,
  sourceBlockNumber: progress.sourceBlockNumber,
  addressRows,
}

type initialState = {
  cleanRun: bool,
  // On a resume this is what the database holds, not what the config would
  // derive — the ids must never reshuffle under stored rows.
  contractMapping: ContractMapping.t,
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
  // The same ids as checkpoint rows. Postgres ignores these.
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

// A chain that owes the events a config change added their history.
type addedEventsDebt = {
  chainId: ChainId.t,
  events: ResumePlan.addedEvents,
  // Where the catch-up ends: the chain's progress when its process started on
  // it. `None` until then.
  untilBlock: option<int>,
  // The last block the catch-up has indexed. `None` before its first batch.
  progressBlock: option<int>,
}

type holding = StorageClient.holding = Nothing | Initialized | Stranded | Diverged | Outdated

type storage = {
  // Identifier used as the `storage` label on Prometheus metrics.
  name: string,
  // The `storage` label for an entity's loads: one Postgres doesn't keep is
  // served by ClickHouse.
  entityStoreName: Internal.entityConfig => string,
  holding: unit => promise<holding>,
  // Should initialize the storage so we can start interacting with it
  // Eg create connection, schema, tables, etc. `envioInfo` is opaque JSON
  // persisted as part of the same transaction so a fresh schema always
  // carries a matching row — storage doesn't interpret it.
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~contractMapping: ContractMapping.t,
    ~envioInfo: JSON.t,
  ) => promise<initialState>,
  // Read before anything is resumed, so a config the stored one rules out is
  // reported as such rather than as a store tripping over tables it never
  // created.
  readStoredConfig: unit => promise<ResumePlan.stored>,
  // Brings an initialized storage a chain it doesn't have yet: its row, its
  // partitions and its config addresses, as `initialize` would have created
  // them. The chains already there are left untouched.
  addChain: (~chainConfig: Config.chain, ~contractMapping: ContractMapping.t) => promise<unit>,
  // Stores the config that gained `events` together with the debt it brings:
  // every chain the storage holds owes those events their history.
  startAddedEvents: (~envioInfo: JSON.t, ~events: ResumePlan.addedEvents) => promise<unit>,
  readAddedEvents: (~chainIds: array<ChainId.t>) => promise<array<addedEventsDebt>>,
  // Pins where each chain's catch-up ends at the chain's progress. Only for
  // the process that drives the chains, before it indexes them any further:
  // nothing else can say their progress has stopped moving. A chain already
  // begun is left as it is.
  beginAddedEvents: (~chainIds: array<ChainId.t>) => promise<unit>,
  // Clears the debt of the chains that have begun.
  finishAddedEvents: (~chainIds: array<ChainId.t>) => promise<unit>,
  // `chainIds` is what this process indexes, and all it reads: a split run's
  // sibling reads its own chains, whose addresses can number tens of millions.
  // Only reads, so a resume refused on what it found leaves the stores alone.
  resumeInitialState: (
    ~chainIds: array<ChainId.t>,
    ~contractMapping: ContractMapping.t,
  ) => promise<initialState>,
  // Takes the chains over once their resume is accepted: ClickHouse is trimmed
  // past `committed`, the frontier the resume read, which is where the run's
  // checkpoint ids continue. Chains a sibling process is still writing must
  // stay out of it.
  takeOver: (~committed: Frontier.t) => promise<unit>,
  // Where the chains stand, for a supervisor, which indexes none of them.
  readChainProgress: (~chainIds: array<ChainId.t>) => promise<array<chainProgress>>,
  // Returns rows matching the filter.
  // Field values are serialized and rows parsed with the table's field schemas.
  // `ConnectionLost` when the connection went, which a load can simply run
  // again.
  @raises("StorageError")
  loadOrThrow: (~filter: EntityFilter.t, ~table: Table.table) => promise<array<unknown>>,
  // Creates whatever indexes the filters need and aren't there yet, resolving
  // once they're queryable. Best-effort: it resolves even when a build fails,
  // leaving the query to run unindexed rather than failing the handler.
  ensureQueryIndexes: (
    ~entityConfig: Internal.entityConfig,
    ~scope: Internal.chainScope,
    ~filters: array<EntityFilter.t>,
  ) => promise<unit>,
  // Creates every index the schema promises for the given chains, without
  // touching `ready_at`. For a resumed indexer that is already ready and so
  // never runs `finalizeBackfill`: an index dropped or invalidated while it was
  // down would otherwise never be rebuilt. Best-effort, and safe to run with
  // indexing live.
  ensureSchemaIndexes: (~chainIds: array<ChainId.t>) => promise<unit>,
  // Creates every index the schema promises for the given chains, then stamps
  // `ready_at` on them. Called once those chains finish backfill. The indexes
  // are committed one at a time so a failure part way through doesn't undo the
  // ones already built; `ready_at` is only written once they all verify.
  finalizeBackfill: (~chainIds: array<ChainId.t>, ~readyAt: Date.t) => promise<unit>,
  // This is to download cache from the database to .envio/cache
  dumpEffectCache: unit => promise<unit>,
  reset: unit => promise<unit>,
  // Update chain metadata. Throws `ConnectionLost` when the connection went:
  // the upsert lands the same however often it is sent.
  setChainMeta: dict<InternalTable.Chains.metaFields> => promise<unknown>,
  // Prune old checkpoints
  pruneStaleCheckpoints: (
    ~safeCheckpoints: CheckpointSequence.checkpointBoundsByChain,
  ) => promise<unit>,
  // Prune stale entity history
  pruneStaleEntityHistory: (
    ~entityConfig: Internal.entityConfig,
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
  // Each chain's committed frontier. `ConnectionLost` when the connection went.
  readFrontier: unit => promise<Frontier.t>,
  // Write batch to storage. Throws `ConnectionLost` when the connection went
  // before anything of the batch committed, and `CommitUncertain` when it went
  // with the COMMIT on its way.
  writeBatch: (
    ~batch: Batch.t,
    ~rollback: option<rollback>,
    ~config: Config.t,
    ~updatedEffectsCache: array<updatedEffectCache>,
    ~updatedEntities: array<updatedEntity>,
    // Addresses this batch registered, with the checkpoint that covers them.
    ~registeredAddresses: array<AddressRows.staged>,
    // Chain metadata stale since the last write, persisted in the same
    // transaction so it never races the batch write.
    ~chainMetaData: option<dict<InternalTable.Chains.metaFields>>,
    // Reports each store's write duration (postgres and clickhouse
    // separately), accumulated into the write metrics.
    ~onWrite: (~storage: string, ~timeSeconds: float) => unit,
  ) => promise<unit>,
  // Release any long-lived resources (e.g. the postgres connection pool) so
  // short-lived CLI commands like `db-migrate setup` can exit cleanly.
  close: unit => promise<unit>,
}

// What `prepare` found the storage holding once it is fit for the config.
type prepared =
  // Nothing: it built the storage, and there is nothing to resume.
  | Created(initialState)
  // An earlier run's, with the contract ids its rows were stored under.
  | Existing({contractMapping: ContractMapping.t})

exception StorageError({message: string, reason: exn})

// The database connection went before the operation got through. Raised only
// where sending the operation again as it was is safe: a read, an upsert, or a
// batch nothing of which committed.
exception ConnectionLost(string)

// The connection went while a batch's COMMIT was on its way, so the batch may
// have committed or not. Its frontier, read back, says which.
exception CommitUncertain(string)

// A start the operator has to act on, not a failure: what it says is all they
// need, so it's printed once, without a stack trace.
exception Refused(string)

// A refusal is all the operator needs to read; anything else is logged with
// what it was doing.
let throwRefusalOrLoggedFailure = (exn, ~logger) =>
  switch exn {
  | Refused(message) => JsError.throwWithMessage(message)
  | exn =>
    exn->ErrorHandling.mkLogAndRaise(~logger, ~msg=`Failed to initialize the indexer storage.`)
  }

// Makes the storage fit the config: builds it when there is none, refuses one
// the config can't continue, and adds a chain the config only gained. It reads
// none of the state indexing starts from: that is `resume`'s, for the chains
// of the process indexing them.
let prepare = async (
  storage: storage,
  ~logger,
  ~chainConfigs: array<Config.chain>,
  ~contractMapping,
  ~envioInfo,
  ~resetCommand,
  ~runCommand,
  ~reset=false,
  ~lowercaseAddresses=false,
  // An `envio start --chain` run. It needs the schema to exist already:
  // initializing under it would create rows for this process's chains only,
  // leaving the ones it skipped with no state for their own processes to
  // resume. It is also the one run that may add its chain to the schema.
  ~isolated=false,
  ~startBlockRetry=StartBlockResolver.UntilItAnswers,
  ~sourceTiming=?,
  // Set for a per-chain schema, which can take a new chain under its own
  // `envio start --chain` process.
  ~addChainCommand: option<ChainId.t => string>=?,
  // Set by `envio start --backfill-added-events`.
  ~backfillAddedEvents=false,
  // Named in a refusal whose whole change is events the flag can take.
  ~backfillAddedEventsCommand: option<string>=?,
): prepared =>
  try {
    let holding = reset ? Nothing : await storage.holding()
    if holding === Stranded {
      throw(Refused(Config.strandedMessage(~resetCommand)))
    }
    if holding === Nothing {
      if isolated {
        throw(
          Refused(
            "`envio start --chain` needs a database that is already set up. Run `envio local db-migrate up` once with the full config, then start a process per chain.",
          ),
        )
      }
      logger->Logger.info(`Initializing the indexer storage...`)
      // Only runs once per schema (this branch is the "first deploy or
      // reset" gate), which is exactly when a `latest` start block must be
      // resolved: every later resume reads `envio_chains.start_block` back
      // verbatim instead of re-running this.
      let waitsOnAnRpc = chainConfigs->Array.some((chain: Config.chain) =>
        switch chain.startBlock {
        | Latest => true
        | Block(_) => false
        }
      )
      let chainConfigs = await chainConfigs->StartBlockResolver.resolveAllOrThrow(
        ~logger,
        ~lowercaseAddresses,
        ~retry=startBlockRetry,
        ~timing=?sourceTiming,
      )

      // The RPC answers when it does, and another indexer can set the
      // storage up meanwhile: it's checked again before it's built over.
      if waitsOnAnRpc && !reset && (await storage.holding()) !== Nothing {
        throw(Refused(Config.setUpMeanwhileMessage))
      }
      let initialState = await storage.initialize(~chainConfigs, ~contractMapping, ~envioInfo)
      logger->Logger.info(`The indexer storage is ready. Starting indexing!`)
      Created(initialState)
    } else {
      logger->Logger.info(`Found existing indexer storage.`)
      let stored = await storage.readStoredConfig()
      let incompatible = paths => Refused(
        ResumePlan.incompatibleMessage(
          paths,
          ~envioInfo,
          ~resetCommand,
          ~runCommand,
          ~addChainCommands=switch addChainCommand {
          // An `envio start --chain` run meets the same storage, and is
          // refused for it before it adds anything.
          | Some(_) if holding === Diverged || holding === Outdated => []
          | Some(addChainCommand) =>
            paths
            ->ResumePlan.newChainIdsWhenOnlyChange(
              ~stored,
              ~envioInfo,
              ~chainConfigs,
              ~contractMapping,
            )
            ->Array.map(addChainCommand)
          | None => []
          },
          ~backfillAddedEventsCommand=?switch backfillAddedEventsCommand {
          | Some(_)
            if holding === Initialized &&
            stored->ResumePlan.addedEventsRefusal(~envioInfo)->Option.isNone &&
            ResumePlan.isAddedEventsOnlyChange(
              ~stored,
              ~envioInfo,
              ~chainConfigs,
              ~contractMapping,
              ~isolated,
            ) => backfillAddedEventsCommand
          | _ => None
          },
        ),
      )
      switch ResumePlan.make(
        ~stored,
        ~envioInfo,
        ~chainConfigs,
        ~contractMapping,
        ~isolated,
        ~backfillAddedEvents,
      ) {
      | Incompatible(changedPaths) => throw(incompatible(changedPaths))
      // After Incompatible: a config change is reported first, since its message names what to revert.
      | _ if holding === Diverged => throw(Refused(Config.divergedMessage(~resetCommand)))
      | _ if holding === Outdated => throw(incompatible([ResumePlan.olderEnvio]))
      | Resume => ()
      | AddChain(chainConfig) =>
        logger->Logger.info(
          `Adding the chain to the existing indexer storage...`,
          ~params={"chainId": chainConfig.id},
        )
        // The same resolution `initialize` runs, and for the same reason:
        // this is the one time the chain's row is written.
        let chainConfig =
          (
            await [chainConfig]->StartBlockResolver.resolveAllOrThrow(
              ~logger,
              ~lowercaseAddresses,
              ~retry=startBlockRetry,
              ~timing=?sourceTiming,
            )
          )->Array.getUnsafe(0)
        await storage.addChain(~chainConfig, ~contractMapping=stored.contractMapping)
      | AddEvents(events) =>
        switch stored->ResumePlan.addedEventsRefusal(~envioInfo) {
        | Some(message) => throw(Refused(message))
        | None =>
          logger->Logger.info(
            `Taking the events config.yaml gained into the existing indexer storage. Each chain indexes them from its start block up to where it stands, and carries on at the head meanwhile.`,
            ~params={"events": events},
          )
          await storage.startAddedEvents(~envioInfo, ~events)
        }
      }
      Existing({contractMapping: stored.contractMapping})
    }
  } catch {
  | exn => exn->throwRefusalOrLoggedFailure(~logger)
  }

// The commands a refusal names, for the command the operator ran.
let resetCommandForRun = (~config, ~isDevelopmentMode) =>
  (isDevelopmentMode ? "envio dev -r" : "envio start -r")->Config.withProjectFlags(~config)
let runCommandForRun = (~config, ~isDevelopmentMode) =>
  (isDevelopmentMode ? "envio dev" : "envio start")->Config.withProjectFlags(~config)

// Takes over the chains this process indexes from what earlier runs stored.
// Taking over trims ClickHouse back to what Postgres committed for them, so it
// is only for a process about to index them, and only once what it read holds
// up. The config's addresses are checked here rather than in `prepare`: they
// sit in the address table among every registered one, which only the resume
// of their chain reads.
let resume = async (
  storage: storage,
  ~logger,
  ~config: Config.t,
  ~isDevelopmentMode,
  ~contractMapping,
) =>
  try {
    let chainConfigs = config.chainMap->ChainMap.values
    let chainIds = chainConfigs->Array.map(chain => chain.id)
    let initialState = await storage.resumeInitialState(~chainIds, ~contractMapping)
    switch chainConfigs
    ->Array.filterMap(chainConfig =>
      initialState.chains
      ->Array.find(chain => chain.id === chainConfig.id)
      ->Option.map(chain => (chainConfig, chain.addressRows))
    )
    ->ResumePlan.changedConfigAddressPaths(
      ~ecosystem=(config.ecosystem.name :> string),
      ~contractMapping,
      ~lowercaseAddresses=config.lowercaseAddresses,
    ) {
    | [] => ()
    | changedPaths =>
      throw(
        Refused(
          changedPaths->ResumePlan.incompatibleMessage(
            ~envioInfo=config.envioInfo,
            ~resetCommand=resetCommandForRun(~config, ~isDevelopmentMode),
            ~runCommand=Some(runCommandForRun(~config, ~isDevelopmentMode)),
          ),
        ),
      )
    }
    await storage.takeOver(~committed=initialState.checkpointFrontier)
    let progress = Dict.make()
    initialState.chains->Array.forEach(chain =>
      progress->ChainId.Dict.set(chain.id, chain.progressBlockNumber)
    )
    logger->Logger.info(
      `Successfully resumed indexing state! Continuing from the last checkpoint.`,
      ~params={"progress": progress},
    )
    initialState
  } catch {
  | exn => exn->throwRefusalOrLoggedFailure(~logger)
  }

// Brings the schema up to date for a run that is about to start, as opposed to
// a migration command: what a config change prints names the command the
// operator ran, and an unreachable chain is waited on rather than reported,
// since somebody is watching the run come up.
let prepareForRun = (
  storage: storage,
  ~logger,
  ~config: Config.t,
  ~reset,
  ~isDevelopmentMode,
  ~startBlockRetry=?,
  ~sourceTiming=?,
) =>
  storage->prepare(
    ~logger,
    ~startBlockRetry?,
    ~sourceTiming?,
    ~reset,
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~envioInfo=config.envioInfo,
    ~resetCommand=resetCommandForRun(~config, ~isDevelopmentMode),
    ~runCommand=Some(runCommandForRun(~config, ~isDevelopmentMode)),
    ~lowercaseAddresses=config.lowercaseAddresses,
    ~isolated=config.isolated,
    ~addChainCommand=?config->Config.addChainCommand,
    ~backfillAddedEvents=config.backfillAddedEvents,
    ~backfillAddedEventsCommand=?isDevelopmentMode
      ? None
      : Some("envio start --backfill-added-events"->Config.withProjectFlags(~config)),
  )

// What a process indexing the config's chains starts from.
let initForRun = async (
  storage: storage,
  ~logger,
  ~config: Config.t,
  ~reset,
  ~isDevelopmentMode,
  ~startBlockRetry=?,
  ~sourceTiming=?,
) =>
  switch await storage->prepareForRun(
    ~logger,
    ~config,
    ~reset,
    ~isDevelopmentMode,
    ~startBlockRetry?,
    ~sourceTiming?,
  ) {
  | Created(initialState) => initialState
  | Existing({contractMapping}) =>
    await storage->resume(~logger, ~config, ~isDevelopmentMode, ~contractMapping)
  }

// Where every chain of a split run stands. The supervisor indexes none of them,
// so it resumes none either: each worker resumes its own.
let initForSupervisor = async (storage: storage, ~logger, ~config: Config.t, ~reset) =>
  switch await storage->prepareForRun(~logger, ~config, ~reset, ~isDevelopmentMode=config.isDev) {
  | Created(initialState) => initialState.chains->Array.map(chain => (chain :> chainProgress))
  | Existing(_) =>
    try {
      await storage.readChainProgress(
        ~chainIds=config.chainMap->ChainMap.values->Array.map(chain => chain.id),
      )
    } catch {
    | exn => exn->throwRefusalOrLoggedFailure(~logger)
    }
  }
