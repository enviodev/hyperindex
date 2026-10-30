type metric = {
  value: string,
  labels: dict<string>,
}

let loadAllQuery = (~pgSchema, ~tableName) => `SELECT * FROM "${pgSchema}"."${tableName}";`

// Which persistence a run is exercised against: Postgres alone, every entity
// kept in ClickHouse alone instead, or every entity kept in both, where a batch
// writes each store and a read checks the two copies agree. A scenario whose
// config sets its own storage keeps it on every leg. CI runs the suite once per
// backend.
type backend = [#postgres | #clickhouse | #both]

@module("node:os") external tmpdir: unit => string = "tmpdir"
@module("node:fs") external rmSync: (string, {"recursive": bool, "force": bool}) => unit = "rmSync"

let backendName = (backend: backend) =>
  switch backend {
  | #postgres => "postgres"
  | #clickhouse => "clickhouse"
  | #both => "both"
  }

let selectedBackend: backend = switch %raw(`process.env.ENVIO_TEST_STORAGE`)->Nullable.toOption {
| None | Some("") | Some("postgres") => #postgres
| Some("clickhouse") => #clickhouse
| Some("both") => #both
| Some(other) =>
  JsError.throwWithMessage(
    `Unknown ENVIO_TEST_STORAGE value "${other}". Expected postgres, clickhouse or both.`,
  )
}

// One row of `envio_addresses`, with its key rendered back to a string.
type addressRow = {
  chainId: ChainId.t,
  address: Address.t,
  contractName: string,
  registrationBlock: int,
}

// A chain's `envio_chains` row, as Postgres keeps it.
type chainRow = {
  id: ChainId.t,
  startBlock: int,
  progressBlock: int,
  firstEventBlock: option<int>,
  readyAt: option<Date.t>,
}

// A logged line as a test reads it: what was said, and the fields said with it.
type logEntry = {msg: string, params: dict<JSON.t>}

type rec t = {
  getBatchWritePromise: unit => promise<unit>,
  getRollbackReadyPromise: unit => promise<unit>,
  waitUntilIdle: unit => promise<unit>,
  waitUntilReady: unit => promise<unit>,
  query: 'entity. string => promise<array<'entity>>,
  queryHistory: 'entity. string => promise<array<Change.t<'entity>>>,
  queryRaw: 'entity. Internal.entityConfig => promise<array<'entity>>,
  // `envio_addresses` isn't an entity, so it has a read path of its own. The
  // stored key is rendered back here, the only place a test needs a string.
  queryAddresses: unit => promise<array<addressRow>>,
  queryCheckpoints: unit => promise<array<InternalTable.Checkpoints.t>>,
  // Ordered by chain id.
  queryChains: unit => promise<array<chainRow>>,
  queryEffectCache: 'input 'output. (
    Envio.effect<'input, 'output>,
    ~scope: Internal.chainScope,
  ) => promise<array<{"id": string, "output": JSON.t}>>,
  metric: string => promise<array<metric>>,
  pgSchema: string,
  // Skipped, without calling back, when the run's config keeps no entity in
  // Postgres, as the harness ClickHouse leg does.
  usePostgresSql: (StorageClient.t => promise<unit>) => promise<unit>,
  // Quiesce the run: its loops keep driving the database otherwise, and the
  // schema is dropped out from under them at the end of `run`.
  stop: unit => promise<unit>,
  // `~chains` resumes the same schema driving only those chains, the way
  // `envio start --chain` does. The chains left out keep their stored state.
  // `~config` resumes under an edited config.yaml, and later restarts keep it.
  // `~reset` starts over on an emptied schema, the way `envio dev -r` does.
  // `~asWorker` leaves the resume unannounced, as a process a supervisor forked
  // does.
  restart: (
    ~config: Config.t=?,
    ~chains: array<ChainId.t>=?,
    ~reset: bool=?,
    ~asWorker: bool=?,
    unit,
  ) => promise<t>,
  // Another process on the same schema, started while this one keeps running,
  // the way the workers of a split run share one. The global persistence is the
  // last one started's, so a handler can't tell siblings apart.
  sibling: (~chains: array<ChainId.t>) => promise<t>,
  // Writes the effect cache out to this run's own cache directory, where the
  // next initialize uploads it from.
  dumpEffectCache: unit => promise<unit>,
  // What an operator sees by default: every line at info and above this run has
  // logged so far, in order — the run's own and its chains'.
  infoAndAboveLogs: unit => array<logEntry>,
  // Every line this run has logged so far, trace included, as the JSON objects
  // the logger wrote: `level` and `msg`, then the fields.
  allLogsAsJson: unit => array<dict<JSON.t>>,
  // Stands in for the supervisor's go-ahead in a run started with
  // `~holdRealtime`.
  releaseRealtime: unit => unit,
}

// How often the stand-in supervisor of a supervised pass asks whether the run
// may go realtime. Short enough that the run gets there in the same tick a test
// would otherwise see it.
%%private(let releaseCheckIntervalMillis = 1)

let entityConfigByName = (config: Config.t, name): Internal.entityConfig =>
  config.userEntitiesByName->Dict.get(name)->Option.getOrThrow

let toInfoLogEntry = (line: dict<JSON.t>) =>
  switch (line->Dict.get("level"), line->Dict.get("msg")) {
  | (Some(String(level)), Some(String(msg)))
    if level->(Utils.magic: string => Logger.level)->Logger.levelNumber >=
      Logger.levelNumber(#info) =>
    Some({
      msg,
      params: line
      ->Dict.toArray
      ->Array.filter(((key, _)) => key !== "msg" && key !== "level")
      ->Dict.fromArray,
    })
  | _ => None
  }

@set external setErrorMessage: (JsExn.t, string) => unit = "message"
type rescriptExn = {@as("RE_EXN_ID") id: string, mutable message?: string}

// Adds to what a failure says without replacing it: vitest still gets the
// AssertionError itself to diff, and a ReScript exception still matches as the
// same exception. A thrown string or a frozen error can't carry the text, and
// stays the failure as thrown.
let appendToFailureMessage = (exn, text) =>
  try {
    switch exn {
    | JsExn(error) => error->setErrorMessage(error->JsExn.message->Option.getOr("") ++ text)
    | exn =>
      let raw = exn->(Utils.magic: exn => rescriptExn)
      raw.message = Some(raw.message->Option.getOr(raw.id) ++ text)
    }
  } catch {
  | _ => ()
  }

let logsLinkPrefix = "\n\nLogs: "

// What a failure said before the link to its run's logs, which differs per run.
let stripLogsLink = message =>
  switch message->String.lastIndexOf(logsLinkPrefix) {
  | -1 => message
  | index => message->String.slice(~start=0, ~end=index)
  }

@module("vitest") @scope("expect")
external vitestState: unit => {"currentTestName": Nullable.t<string>} = "getState"

// A failed run's logs go to a file its failure names, rather than into the test
// output: most failures don't need them, and the ones that do need all of them.
let writeLogsForFailure = (logger, ~pgSchema) => {
  let testName =
    vitestState()["currentTestName"]
    ->Nullable.toOption
    ->Option.mapOr("", name => name->String.replaceRegExp(/[^A-Za-z0-9]+/g, "-") ++ "-")
  let path =
    NodeJs.Path.resolve([
      NodeJs.Process.cwd(),
      ".test-logs",
      `${testName->String.slice(~start=0, ~end=120)}${pgSchema}.jsonl`,
    ])->NodeJs.Path.toString
  logger->Logger.writeInMemoryLinesToFile(~path)
  path
}

// Runs `body` against a fresh indexer in a Postgres schema of its own, then
// tears both down — so tests never stop an indexer by hand, and files can run
// in parallel against one database. Cleanup runs even when the body throws,
// otherwise a failing test would leave its schema and connections behind.
//
// `config` is already fully resolved: the chains it indexes, its source
// configs and every knob the yaml owns are decided by the caller.
let run = async (
  ~config: Config.t,
  ~resolveRegistrations: (~config: Config.t) => promise<HandlerRegister.registrationsByChainId>,
  // One capture for the whole run, `restart` and siblings included, so a test
  // reads the resumed indexer's lines after the ones that led to them.
  ~logger=Logger.makeInMemory(),
  ~sourceTiming=?,
  ~startBlockRetry=?,
  ~targetBufferSize=?,
  // Runs the indexer the way a supervised worker runs: it waits to be released
  // before entering the reorg threshold or switching to realtime.
  ~holdRealtime=false,
  // Runs it behind the same barrier with a stand-in supervisor releasing it on
  // the real predicate, so a scenario exercises the held path without a test
  // having to drive it. A split run can't be simulated here — the sources a
  // test drives are objects in this process, which a forked worker wouldn't
  // have — but the hold, the predicate and the release are the production ones.
  ~superviseRun=false,
  ~onError=?,
  ~onExit=?,
  ~mapStorage: Persistence.storage => Persistence.storage=storage => storage,
  // Runs after `restart` has stopped the previous indexer and before the next
  // one starts, so mocked sources can void what the stopped one left in flight.
  ~onIndexerStopped: unit => unit=() => (),
  // Leaves the `ENVIO_CLICKHOUSE_*` settings to the environment rather than
  // pointing them at a database of the run's own, for a test about a run that
  // has none.
  ~provideClickHouse=true,
  // Starts the first process the way `envio start --chain` does, on storage
  // nothing has set up yet.
  ~chains=?,
  body: t => promise<unit>,
) => {
  // Postgres resources this run owns: one schema, plus every client and
  // indexer built inside it (`restart` adds more).
  let pgSchema = TestPgSchema.make()
  // Handler files log through `console` as they load and run, so the run's
  // capture holds those lines too.
  let restoreConsole = logger->Logger.routeConsole(~loggerFor=RunScope.loggerFor)
  let cacheDir = NodeJs.Path.resolve([tmpdir(), `envio-cache-${pgSchema}`])
  let clients = []
  let storages: array<Persistence.storage> = []
  let stops = []

  // Unless the test handles indexer errors itself, the first one fails the run
  // with its own message. Exiting the process instead kills the vitest worker
  // without naming the test or the error.
  let indexerFailure = ref(None)
  let resolveFailure = ref(None)
  let failed = Promise.make((resolve, _) => resolveFailure := Some(resolve))
  let failWith = (errHandler: ErrorHandling.t) =>
    if indexerFailure.contents->Option.isNone {
      let exn = errHandler->ErrorHandling.toExn
      indexerFailure := Some(exn)
      resolveFailure.contents->Option.forEach(resolve => resolve(exn))
    }

  // The run stops waiting on a body once its indexer fails, but the body keeps
  // going. An indexer it starts after that would outlive the teardown.
  let isClosing = ref(false)
  let throwIfClosing = () =>
    if isClosing.contents {
      JsError.throwWithMessage("Can't start an indexer once the run is tearing down.")
    }

  // ClickHouse writes into a database of this run's own, whenever the config it
  // runs under enables it — a restart's included. Only a run that pointed an
  // indexer at it drops it, so a run that never does needs no server.
  let clickHouseDatabase = provideClickHouse ? Some(TestClickHouse.make()) : None
  let usedClickHouse = ref(false)
  let restoreClickHouseEnv = TestClickHouse.savedEnv()

  // The builder is only reachable here and from `restart`, so it takes just
  // what differs between them and reads the rest off this call.
  let rec make = async (~reset, ~config as baseConfig, ~chains=?, ~asWorker=false) => {
    throwIfClosing()
    let config = switch chains {
    | Some(chainIds) => baseConfig->Config.isolate(~chainIds)
    | None => baseConfig
    }
    switch clickHouseDatabase {
    | Some(database) if config.storage.clickhouse =>
      TestClickHouse.use(~database)
      usedClickHouse := true
    | _ => ()
    }
    let sql = TestPgSchema.client(~logger)
    clients->Array.push(sql)->ignore
    // Tracking tables in Hasura costs ~1.9 seconds per indexer.
    let client = Storage.clientFromEnv(~config, ~logger, ~pgSchema, ~isHasuraEnabled=false)
    let storage = mapStorage(
      Storage.make(
        ~client,
        ~logger,
        ~entities=config.userEntities,
        ~cacheDir,
        ~ecosystem=config.ecosystem.name,
        ~isolated=config.isolated,
      ),
    )
    storages->Array.push(storage)
    let persistence = Storage.makePersistenceFromConfig(~config, ~logger, ~storage)
    // `Main.start` does this before handler modules load, so the exported
    // indexer can expose persisted state. Without it every `indexer.chains[N]`
    // getter silently falls back to static config.
    Main.setGlobalPersistence(persistence)

    let onError = switch onError {
    | Some(onError) => onError
    | None => failWith
    }

    await persistence->Persistence.initForRun(
      ~logger,
      ~config,
      ~reset,
      ~isDevelopmentMode=true,
      ~announceResume=!asWorker,
      ~startBlockRetry?,
      ~sourceTiming?,
    )

    // Same order as `Main.start`: storage is initialized - which is where a
    // `start_block: latest` chain reads its head - before handler modules load,
    // so a registration-time `chain.startBlock` sees the resolved block.
    let registrationsByChainId = await resolveRegistrations(~config)
    // The client above is already in `clients`, so teardown still closes it;
    // only the loop must not start, since teardown may have passed `stops`.
    throwIfClosing()
    MockSource.installMockSourceRegistrations(~config, ~registrationsByChainId)

    let state = IndexerState.makeFromDbState(
      ~initialState=persistence->Persistence.getInitializedState,
      ~config,
      ~logger,
      ~persistence,
      ~registrationsByChainId,
      ~sourceTiming?,
      ~targetBufferSize?,
      ~isDevelopmentMode=false,
      ~shouldUseTui=false,
      ~holdRealtime={holdRealtime || superviseRun},
      ~onError,
      ~onExit?,
    )
    state->IndexerLoop.start

    // Only when the test didn't ask for the hold itself: one that did is
    // testing the barrier and owns its own release.
    let releaseCheck = ref(None)
    if superviseRun && !holdRealtime {
      releaseCheck := Some(setInterval(() =>
            if state->IndexerState.hasArrivedAtHead {
              releaseCheck.contents->Option.forEach(clearInterval)
              releaseCheck := None
              state->IndexerState.releaseRealtime
            }
          , releaseCheckIntervalMillis))
    }

    // Persist before stopping, else a resumed indexer loses uncommitted state,
    // then let any in-flight batch or write settle so nothing from this run
    // lands on the database afterwards.
    // Idempotent: `restart` stops the previous indexer, and so does the `run`
    // teardown that stops every indexer the scope created.
    let stopped = ref(None)
    let stop = () =>
      switch stopped.contents {
      | Some(promise) => promise
      | None =>
        let promise = (
          async () => {
            releaseCheck.contents->Option.forEach(clearInterval)
            releaseCheck := None
            await state->Writing.flush
            state->IndexerState.stop
            // Tests deliberately leave handlers that never resolve, which pins
            // `isProcessing` for good — so that wait is short and giving up on
            // it is expected.
            let processingDeadline = Date.now() +. 2000.
            while state->IndexerState.isProcessing && Date.now() < processingDeadline {
              await Utils.delay(1)
            }
            // A write is different: `run` drops the schema straight after, and
            // a write landing on the dropped schema fails the whole worker. No
            // test blocks one indefinitely, so this bound is a backstop rather
            // than something any run is expected to hit.
            let writeDeadline = Date.now() +. 30_000.
            while state->IndexerState.writeFiber->Option.isSome && Date.now() < writeDeadline {
              await Utils.delay(1)
            }
          }
        )()
        stopped := Some(promise)
        promise
      }
    stops->Array.push(stop)->ignore

    // An entity's ClickHouse copy is read through the run's own client, which
    // sees what the indexer has committed. A read goes to Postgres whenever it
    // keeps the entity, so the table is registered as ClickHouse's alone.
    // Registered once per client: the handle is what a read names the table by.
    let clickHouseTables = Dict.make()
    let clickHouseTable = (entityConfig: Internal.entityConfig) =>
      switch clickHouseTables->Dict.get(entityConfig.name) {
      | Some(handle) => handle
      | None =>
        let handle = (
          client->Storage.registerEntity({
            ...entityConfig,
            storage: {...entityConfig.storage, postgres: false},
          })
        ).handle
        clickHouseTables->Dict.set(entityConfig.name, handle)
        handle
      }
    let clickHouseRows = (entityConfig: Internal.entityConfig) =>
      client
      ->StorageClient.loadWhere(~table=clickHouseTable(entityConfig), ~conditions=[])
      ->(Utils.magic: promise<array<dict<unknown>>> => promise<array<unknown>>)
    let postgresRows = (entityConfig: Internal.entityConfig) =>
      sql->Sql.queryForTests(loadAllQuery(~pgSchema, ~tableName=entityConfig.table.tableName))

    // Rows come back decoded: both stores' rows parse with the table's field
    // schemas.
    let parseRows = (entityConfig: Internal.entityConfig, rows): array<unknown> =>
      rows->S.parseOrThrow(entityConfig.table->Table.pgRowsSchema)

    // Two chains can keep an entity under the same id, so the chain is part of
    // what orders the rows.
    let sortedRows = (entityConfig: Internal.entityConfig, rows: array<unknown>) => {
      let chainField =
        entityConfig.table->Table.getChainIdField->Option.map(field => field.fieldName)
      let idKey = entityConfig.table->Table.idKey
      let keyOf = row => {
        let row = row->(Utils.magic: unknown => dict<unknown>)
        let id = idKey(row->Dict.getUnsafe("id")->EntityId.unsafeOfAny)
        switch chainField {
        | Some(field) => `${id}|${row->Dict.getUnsafe(field)->Utils.Hash.makeOrThrow}`
        | None => id
        }
      }
      rows->Array.toSorted((a, b) => String.compare(keyOf(a), keyOf(b)))
    }

    // An entity kept in both stores is read from Postgres, and its ClickHouse
    // copy is held to the same rows: each store is written apart, and this is
    // where a copy that drifted shows up. ClickHouse publishes a batch just
    // after Postgres commits it, so a read right behind a commit can find the
    // copy a batch short for a moment.
    let rec clickHouseAgrees = async (entityConfig, ~expected, ~attempts) => {
      let copy = sortedRows(
        entityConfig,
        parseRows(entityConfig, await clickHouseRows(entityConfig)),
      )
      let agrees = try {
        Vitest.expect(
          copy,
          ~message=`ClickHouse's copy of ${entityConfig.name} holds what Postgres does`,
        ).toEqual(expected)
        true
      } catch {
      | _ if attempts > 1 => false
      }
      if !agrees {
        await Utils.delay(50)
        await clickHouseAgrees(entityConfig, ~expected, ~attempts=attempts - 1)
      }
    }

    let queryEntity = async (entityConfig: Internal.entityConfig) =>
      switch entityConfig.storage {
      | {postgres: false} => parseRows(entityConfig, await clickHouseRows(entityConfig))
      | {clickhouse: false} => parseRows(entityConfig, await postgresRows(entityConfig))
      | _ =>
        let rows = parseRows(entityConfig, await postgresRows(entityConfig))
        await clickHouseAgrees(entityConfig, ~expected=sortedRows(entityConfig, rows), ~attempts=40)
        rows
      }

    // Which chain a stored row belongs to, for a table that has chains at all.
    // Read off the row rather than the change decoded from it: a delete keeps
    // only its id and checkpoint, and two chains can share both.
    let chainIdOfRow = (entityConfig: Internal.entityConfig) =>
      switch entityConfig.table->Table.getChainIdField {
      | None => _ => 0.
      | Some(field) =>
        row =>
          switch row
          ->(Utils.magic: unknown => dict<unknown>)
          ->Utils.Dict.dangerouslyGetNonOption(field->Table.getPgDbFieldName) {
          // Text when the chain-id column is a bigint.
          | Some(value) if typeof(value) === #string =>
            value->(Utils.magic: unknown => string)->Float.fromString->Option.getOr(0.)
          | Some(value) => value->(Utils.magic: unknown => float)
          | None => 0.
          }
      }

    // ClickHouse's history is its state, so it holds every change: those a
    // rollback reverted stay, followed by the rows restoring them. Postgres's
    // holds only changes in the reorg window, pruned, and a rollback deletes
    // what it reverts.
    let historyRows = (entityConfig: Internal.entityConfig): promise<array<unknown>> =>
      switch entityConfig.storage {
      | {postgres: false} =>
        client
        ->StorageClient.historyForTests(~table=clickHouseTable(entityConfig))
        ->(Utils.magic: promise<array<dict<unknown>>> => promise<array<unknown>>)
      | _ =>
        sql->Sql.queryForTests(
          loadAllQuery(
            ~pgSchema,
            ~tableName=EntityHistory.historyTableName(
              ~entityName=entityConfig.name,
              ~entityIndex=entityConfig.index,
            ),
          ),
        )
      }

    let queryEntityHistory = (entityConfig: Internal.entityConfig) => {
      let chainIdOfRow = chainIdOfRow(entityConfig)
      let idKey = entityConfig.table->Table.idKey
      historyRows(entityConfig)->Promise.thenResolve(items => {
        // Rows aren't ordered by the query, and insert order isn't meaningful
        // since checkpointId is the source of truth. Sort for stable assertions.
        let changes = items->S.parseOrThrow(
          S.array(
            S.union([
              EntityHistory.makeSetUpdateSchema(
                ~idSchema=entityConfig.table->Table.getIdSchema,
                entityConfig->Storage.getRowSchema,
              ),
              S.object((s): Change.t<Internal.entity> => {
                s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
                Delete({
                  entityId: s.field("id", entityConfig.table->Table.getIdSchema),
                  checkpointId: s.field(
                    EntityHistory.checkpointIdFieldName,
                    EntityHistory.unsafeCheckpointIdSchema,
                  ),
                })
              }),
            ]),
          ),
        )
        changes
        ->Array.mapWithIndex((change, index) => (
          change,
          chainIdOfRow(items->Array.getUnsafe(index)),
        ))
        ->Array.toSorted(((a, aChain), (b, bChain)) => {
          switch String.compare(idKey(a->Change.getEntityId), idKey(b->Change.getEntityId)) {
          | 0. =>
            // Compared as bigints: checkpoint ids are unbounded, and past 2^53
            // a float comparison would call distinct ids equal.
            let (aCheckpoint, bCheckpoint) = (a->Change.getCheckpointId, b->Change.getCheckpointId)
            if aCheckpoint < bCheckpoint {
              -1.
            } else if aCheckpoint > bCheckpoint {
              1.
            } else {
              // A per-chain entity gives every chain its own row under the same
              // id and checkpoint, and nothing above tells those apart. The
              // statements that wrote them run together in one transaction, so
              // which landed first says nothing.
              Float.compare(aChain, bChain)
            }
          | order => order
          }
        })
        ->Array.map(((change, _)) => change)
      })
    }

    {
      getBatchWritePromise: () => {
        Utils.Promise.makeAsync(async (resolve, _reject) => {
          let before = state->IndexerState.processedBatchesCount
          // Wait until a new batch is processed and written. A reorg batch can
          // land before this call (e.g. while the test awaits the rollback), so
          // also stop once the indexer has fully settled.
          let idleChecks = ref(0)
          let rec wait = async () => {
            await state->Writing.flush
            let isIdle =
              !(state->IndexerState.isProcessing) &&
              state->IndexerState.writeFiber->Option.isNone &&
              Frontier.equals(
                state->IndexerState.committedFrontier,
                state->IndexerState.processedFrontier,
              )

            // Catching up hands off to the FinalizingIndexes phase, which is
            // where readiness is decided — so a batch isn't settled until that
            // phase is over. The idle fallback below still bounds the wait.
            if (
              before < state->IndexerState.processedBatchesCount &&
                !(state->IndexerState.shouldFinalizeIndexes)
            ) {
              ()
            } else if isIdle && idleChecks.contents >= 5 {
              ()
            } else {
              idleChecks := if isIdle {
                  idleChecks.contents + 1
                } else {
                  0
                }
              await Utils.delay(1)
              await wait()
            }
          }
          await wait()
          resolve()
        })
      },
      waitUntilIdle: async () => {
        await state->Writing.flush
        // Settling takes several ticks: the loop dispatches follow-up actions
        // (the next query, the finalize pass) from inside the tick that looks
        // idle, so one observation isn't enough.
        let settled = ref(0)
        let attempts = ref(0)
        while settled.contents < 5 && attempts.contents < 5000 {
          attempts := attempts.contents + 1
          settled := if (
              !(state->IndexerState.isProcessing) &&
              state->IndexerState.writeFiber->Option.isNone &&
              !(state->IndexerState.shouldFinalizeIndexes) &&
              Frontier.equals(
                state->IndexerState.committedFrontier,
                state->IndexerState.processedFrontier,
              )
            ) {
              settled.contents + 1
            } else {
              0
            }
          await Utils.delay(0)
        }
        if settled.contents < 5 {
          JsError.throwWithMessage("Timed out waiting for the indexer to go idle")
        }
      },
      releaseRealtime: () => state->IndexerState.releaseRealtime,
      waitUntilReady: async () => {
        let isReady = () =>
          state
          ->IndexerState.chainStates
          ->Dict.valuesToArray
          ->Array.every(chainState => chainState->ChainState.isReady)
        let attempts = ref(0)
        while !isReady() && attempts.contents < 5000 {
          attempts := attempts.contents + 1
          await Utils.delay(0)
        }
        if !isReady() {
          JsError.throwWithMessage("Timed out waiting for the indexer to report ready")
        }
      },
      getRollbackReadyPromise: () => {
        Utils.Promise.makeAsync(async (resolve, _reject) => {
          // Wait for the in-progress rollback to be fully applied. RollbackReady
          // itself is transient (the reprocessing batch consumes it), so observe
          // the rollback flag clearing instead.
          while state->IndexerState.isResolvingReorg {
            await Utils.delay(1)
          }
          // Skip an extra microtask for indexer to fire actions
          await Utils.delay(0)
          resolve()
        })
      },
      query: (type entity, name) =>
        queryEntity(config->entityConfigByName(name))->(
          Utils.magic: promise<array<unknown>> => promise<array<entity>>
        ),
      queryRaw: (type entity, entityConfig: Internal.entityConfig) =>
        queryEntity(entityConfig)->(Utils.magic: promise<array<unknown>> => promise<array<entity>>),
      queryAddresses: async () => {
        let rows =
          (
            await sql->Sql.queryForTests(
              `SELECT "chain_id" AS "chainId", "address", "contract_id" AS "contractId", "registration_block" AS "registrationBlock" FROM "${pgSchema}"."envio_addresses";`,
            )
          )->(Utils.magic: array<unknown> => array<AddressRows.row>)
        let addresses =
          rows->AddressRows.render(
            ~ecosystem=(config.ecosystem.name :> string),
            ~shouldChecksum=!config.lowercaseAddresses,
          )
        rows->Array.mapWithIndex((row, idx): addressRow => {
          chainId: row.chainId->ChainId.normalizeOrThrow,
          address: addresses->Array.getUnsafe(idx),
          contractName: config.contractMapping->ContractMapping.nameOfOrThrow(row.contractId),
          registrationBlock: row.registrationBlock,
        })
      },
      queryHistory: (type entity, name) =>
        queryEntityHistory(config->entityConfigByName(name))->(
          Utils.magic: promise<array<Change.t<Internal.entity>>> => promise<array<Change.t<entity>>>
        ),
      queryCheckpoints: () =>
        sql
        ->Sql.queryForTests(
          `SELECT * FROM "${pgSchema}"."${InternalTable.Checkpoints.tableName}" ORDER BY "id", "chain_id";`,
        )
        ->Promise.thenResolve(rows =>
          rows->Array.map(row => row->S.convertOrThrow(InternalTable.Checkpoints.dbSchema))
        ),
      queryChains: async () => {
        let rows: array<{
          "id": unknown,
          "startBlock": int,
          "progressBlock": int,
          "firstEventBlock": Null.t<int>,
          "readyAt": Null.t<Date.t>,
        }> = await sql->Sql.queryForTests(
          `SELECT "id", "start_block" AS "startBlock", "progress_block" AS "progressBlock", "first_event_block" AS "firstEventBlock", "ready_at" AS "readyAt" FROM "${pgSchema}"."envio_chains" ORDER BY "id";`,
        )
        rows->Array.map(row => {
          id: row["id"]->ChainId.normalizeOrThrow,
          startBlock: row["startBlock"],
          progressBlock: row["progressBlock"],
          firstEventBlock: row["firstEventBlock"]->Null.toOption,
          readyAt: row["readyAt"]->Null.toOption,
        })
      },
      queryEffectCache: (type input output, effect: Envio.effect<input, output>, ~scope) => {
        let effect = effect->(Utils.magic: Envio.effect<input, output> => Internal.effect)
        let tableName = Internal.EffectCache.toTableName(~effectName=effect.name, ~scope)
        sql
        ->Sql.queryForTests(loadAllQuery(~pgSchema, ~tableName))
        ->(Utils.magic: promise<array<unknown>> => promise<array<{"id": string, "output": JSON.t}>>)
      },
      metric: async name => {
        // Parse the metric's samples back out of the rendered /metrics text.
        Metrics.collect(~metrics=Some(state->IndexerState.toMetrics))
        ->String.split("\n")
        ->Array.filterMap(line =>
          if line->String.startsWith(name ++ "{") || line->String.startsWith(name ++ " ") {
            let rest = line->String.slice(~start=name->String.length)
            let (labelsPart, value) = switch rest->String.lastIndexOf(" ") {
            | -1 => ("", rest)
            | i => (rest->String.slice(~start=0, ~end=i), rest->String.slice(~start=i + 1))
            }
            let labels = Dict.make()
            // Quoted values may contain escaped `\"`, `\\` and `\n`, so match
            // label pairs instead of splitting on commas/equals.
            let labelRe = RegExp.fromString(
              `([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\\\]|\\\\.)*)"`,
              ~flags="g",
            )
            let break = ref(false)
            while !break.contents {
              switch labelRe->RegExp.exec(labelsPart) {
              | Some(result) =>
                let matches = result->RegExp.Result.matches
                switch (matches->Array.get(0), matches->Array.get(1)) {
                | (Some(Some(key)), Some(Some(escaped))) =>
                  labels->Dict.set(
                    key,
                    escaped
                    ->String.replaceAll("\\n", "\n")
                    ->String.replaceAll("\\\"", "\"")
                    ->String.replaceAll("\\\\", "\\"),
                  )
                | _ => ()
                }
              | None => break := true
              }
            }
            Some({value, labels})
          } else {
            None
          }
        )
      },
      pgSchema,
      usePostgresSql: check =>
        if config.userEntities->Array.some(e => e.storage.postgres) {
          check(sql)
        } else {
          Promise.resolve()
        },
      stop,
      infoAndAboveLogs: () => logger->Logger.inMemoryLines->Array.filterMap(toInfoLogEntry),
      allLogsAsJson: () => logger->Logger.inMemoryLines,
      sibling: (~chains) => make(~reset=false, ~config=baseConfig, ~chains),
      restart: async (~config=baseConfig, ~chains=?, ~reset=false, ~asWorker=?, ()) => {
        // The previous run has to be quiet before the resumed one takes over the
        // shared persistence, else the two race against the same db.
        await stop()
        onIndexerStopped()
        await make(~reset, ~config, ~chains?, ~asWorker?)
      },
      dumpEffectCache: () => storage.dumpEffectCache(),
    }
  }

  let outcome = try {
    let indexer = await make(~reset=chains->Option.isNone, ~config, ~chains?)
    // A body waiting on progress the failed indexer will never make would
    // otherwise sit until the test times out.
    await Promise.race([
      body(indexer)->Promise.thenResolve(() => indexerFailure.contents),
      failed->Promise.thenResolve(exn => Some(exn)),
    ])
  } catch {
  | exn => Some(exn)
  }
  isClosing := true

  // Every step runs even if an earlier one throws, and a teardown failure
  // never replaces the body's — losing the real failure behind a cleanup
  // error is how a broken test becomes unreadable.
  let teardownFailure = ref(None)
  let attempt = async step =>
    switch await step() {
    | () => ()
    | exception exn =>
      if teardownFailure.contents->Option.isNone {
        teardownFailure := Some(exn)
      }
    }

  // Stop before dropping: a still-running loop would fail its next query
  // against the vanished schema and report that instead of the real failure.
  // After a failed body, a stop can wait on a write the body stalled and was
  // never going to release, which would bury the failure under a suite timeout.
  let boundedStop = stop =>
    switch outcome {
    | Some(_) =>
      () =>
        Promise.race([
          stop(),
          Promise.make((resolve, _reject) =>
            MockSource.realSetTimeout(() => resolve(), 5000)->ignore
          ),
        ])
    | None => stop
    }
  for i in 0 to stops->Array.length - 1 {
    switch stops->Array.get(i) {
    | Some(stop) => await attempt(stop->boundedStop)
    | None => ()
    }
  }
  // Dropped whether the body passed or threw — a leaked schema outlives the
  // information it could have carried, and the sweeper only covers workers
  // that died before getting here.
  switch clients->Array.get(0) {
  | Some(sql) => await attempt(() => sql->TestPgSchema.drop(~pgSchema))
  | None => ()
  }
  switch clickHouseDatabase {
  | Some(database) if usedClickHouse.contents => await attempt(() => TestClickHouse.drop(~database))
  | _ => ()
  }
  restoreClickHouseEnv()
  await attempt(async () =>
    rmSync(cacheDir->NodeJs.Path.toString, {"recursive": true, "force": true})
  )
  for i in 0 to clients->Array.length - 1 {
    switch clients->Array.get(i) {
    | Some(sql) => await attempt(() => sql->StorageClient.close)
    | None => ()
    }
  }
  for i in 0 to storages->Array.length - 1 {
    switch storages->Array.get(i) {
    | Some(storage) => await attempt(() => storage.close())
    | None => ()
    }
  }

  restoreConsole()

  switch (outcome, indexerFailure.contents, teardownFailure.contents) {
  | (Some(exn), _, _)
  | (None, Some(exn), _)
  | (None, None, Some(exn)) =>
    // Written after the teardown, which is still this run's to log. A failed
    // write must not replace the failure it was meant to explain.
    let link = try logger->writeLogsForFailure(~pgSchema) catch {
    | writeExn =>
      `not written (${writeExn
        ->Utils.prettifyExn
        ->Utils.exnMessage
        ->Option.getOr("unknown error")})`
    }
    exn->appendToFailureMessage(logsLinkPrefix ++ link)
    switch exn {
    // Rethrown as caught, so vitest gets the AssertionError itself and can diff
    // it, not a ReScript wrapper it prints as a plain object.
    | JsExn(error) => JsExn.throw(error)
    | exn => throw(exn)
    }
  | (None, None, None) => ()
  }
}
