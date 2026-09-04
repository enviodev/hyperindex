type metric = {
  value: string,
  labels: dict<string>,
}

// The schema this indexer's tables live in, and the run's own client — closed
// with it. A test needing raw SQL should reach for these rather than opening a
// client the run won't clean up.
type pg = {sql: Postgres.sql, pgSchema: string}

// Which persistence a run is exercised against. Both are Postgres-backed; the
// ClickHouse one adds the sink on top. CI runs the suite once per backend.
type backend = [#postgres | #clickhouse]

let backendName = (backend: backend) =>
  switch backend {
  | #postgres => "postgres"
  | #clickhouse => "clickhouse"
  }

let selectedBackend: backend = switch %raw(`process.env.ENVIO_TEST_STORAGE`)->Nullable.toOption {
| None | Some("") | Some("postgres") => #postgres
| Some("clickhouse") => #clickhouse
| Some(other) =>
  JsError.throwWithMessage(
    `Unknown ENVIO_TEST_STORAGE value "${other}". Expected postgres or clickhouse.`,
  )
}

// One row of `envio_addresses`, with its key rendered back to a string.
type addressRow = {
  chainId: ChainId.t,
  address: Address.t,
  contractName: string,
  registrationBlock: int,
}

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
  queryEffectCache: 'input 'output. (
    Envio.effect<'input, 'output>,
    ~scope: Internal.chainScope,
  ) => promise<array<{"id": string, "output": JSON.t}>>,
  metric: string => promise<array<metric>>,
  pg: pg,
  // Quiesce the run: its loops keep driving the database otherwise, and the
  // schema is dropped out from under them at the end of `run`.
  stop: unit => promise<unit>,
  restart: unit => promise<t>,
}

let entityConfigByName = (config: Config.t, name): Internal.entityConfig =>
  config.userEntitiesByName->Dict.get(name)->Option.getOrThrow

// Runs `body` against a fresh indexer in a Postgres schema of its own, then
// tears both down — so tests never stop an indexer by hand, and files can run
// in parallel against one database. Cleanup runs even when the body throws,
// otherwise a failing test would leave its schema and connections behind.
//
// `config` is already fully resolved: the chains it indexes, its source
// configs and every knob the yaml owns are decided by the caller.
let run = async (
  ~config: Config.t,
  ~resolveRegistrations: unit => promise<HandlerRegister.registrationsByChainId>,
  ~backend: backend=selectedBackend,
  ~reducedPollingInterval=?,
  ~targetBufferSize=?,
  ~onError=?,
  ~onExit=?,
  ~mapStorage: Persistence.storage => Persistence.storage=storage => storage,
  // Runs after `restart` has stopped the previous indexer and before the next
  // one starts, so mocked sources can void what the stopped one left in flight.
  ~onIndexerStopped: unit => unit=() => (),
  body: t => promise<unit>,
) => {
  // Postgres resources this run owns: one schema, plus every client and
  // indexer built inside it (`restart` adds more).
  let pgSchema = TestPgSchema.make()
  let clients = []
  let stops = []

  // The ClickHouse leg writes through the sink Postgres storage attaches, into
  // a database of this run's own.
  let clickHouseDatabase = switch backend {
  | #clickhouse => Some(TestClickHouse.make())
  | #postgres => None
  }

  // The builder is only reachable here and from `restart`, so it takes just
  // the flag that differs between them and reads the rest off this call.
  let rec make = async (~reset) => {
    // Silence logs by default in test mode unless LOG_LEVEL is explicitly set
    switch Env.userLogLevel {
    | None => Logging.setLogLevel(#silent)
    | Some(_) => ()
    }

    let registrationsByChainId = await resolveRegistrations()
    MockSource.installMockSourceRegistrations(~config, ~registrationsByChainId)

    switch clickHouseDatabase {
    | Some(database) => TestClickHouse.use(~database)
    | None => ()
    }
    let sql = PgStorage.makeClient()
    clients->Array.push(sql)->ignore
    let storage = mapStorage(
      // Tracking tables in Hasura costs ~1.9 seconds per indexer.
      PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false),
    )
    let persistence = PgStorage.makePersistenceFromConfig(~config, ~storage)
    let pg = {sql, pgSchema}

    let onError = switch onError {
    | Some(onError) => onError
    | None =>
      (errHandler: ErrorHandling.t) => {
        errHandler->ErrorHandling.log
        NodeJs.process->NodeJs.exitWithCode(NodeJs.Failure)
      }
    }

    await persistence->Persistence.init(
      ~chainConfigs=config.chainMap->ChainMap.values,
      ~contractMapping=config.contractMapping,
      ~envioInfo=JSON.Encode.object(Dict.make()),
      ~resetCommand="envio dev -r",
      ~runCommand=Some("envio dev"),
      ~reset,
    )

    let state = IndexerState.makeFromDbState(
      ~initialState=persistence->Persistence.getInitializedState,
      ~config,
      ~persistence,
      ~registrationsByChainId,
      ~reducedPollingInterval?,
      ~targetBufferSize?,
      ~isDevelopmentMode=false,
      ~shouldUseTui=false,
      ~onError,
      ~onExit?,
    )
    state->IndexerLoop.start

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

    // Rows come back decoded: postgres parses them with the table's field schemas.
    let queryEntity = (entityConfig: Internal.entityConfig) =>
      sql
      ->Postgres.unsafe(
        PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=entityConfig.table.tableName),
      )
      ->Promise.thenResolve(items => items->S.parseOrThrow(entityConfig.table->Table.pgRowsSchema))

    let queryEntityHistory = (entityConfig: Internal.entityConfig) =>
      sql
      ->Postgres.unsafe(
        PgStorage.makeLoadAllQuery(
          ~pgSchema,
          ~tableName=PgStorage.getEntityHistory(~entityConfig).table.tableName,
        ),
      )
      ->Promise.thenResolve(items => {
        // Rows aren't ordered by the query, and insert order isn't meaningful
        // since checkpointId is the source of truth. Sort for stable assertions.
        items
        ->S.parseOrThrow(
          S.array(
            S.union([
              PgStorage.getEntityHistory(~entityConfig).setChangeSchema,
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
        ->Array.toSorted((a, b) => {
          switch String.compare(
            a->Change.getEntityId->EntityId.toKey,
            b->Change.getEntityId->EntityId.toKey,
          ) {
          | 0. =>
            // Compared as bigints: checkpoint ids are unbounded, and past 2^53
            // a float comparison would call distinct ids equal.
            let (a, b) = (a->Change.getCheckpointId, b->Change.getCheckpointId)
            if a == b {
              0.
            } else if a < b {
              -1.
            } else {
              1.
            }
          | order => order
          }
        })
      })

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
              state->IndexerState.committedCheckpointId == state->IndexerState.processedCheckpointId

            // Catching up hands off to the FinalizingIndexes phase, which is
            // where readiness is decided — so a batch isn't settled until that
            // phase is over. The idle fallback below still bounds the wait.
            if (
              before < state->IndexerState.processedBatchesCount &&
                !(state->IndexerState.isFinalizingIndexes)
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
          // Skip extra microtasks for indexer to fire follow-up actions
          // (e.g. the NextQuery dispatch that schedules the next
          // getItemsOrThrow call). Without this, callers that immediately
          // call resolveGetItemsOrThrow can race the dispatch and observe
          // an empty calls array.
          await Utils.delay(0)
          await Utils.delay(0)
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
              !(state->IndexerState.isFinalizingIndexes) &&
              state->IndexerState.committedCheckpointId == state->IndexerState.processedCheckpointId
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
          (await sql->Postgres.unsafe(InternalTable.EnvioAddresses.makeGetRowsQuery(~pgSchema)))->(
            Utils.magic: unknown => array<AddressRows.row>
          )
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
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(
            ~pgSchema,
            ~tableName=InternalTable.Checkpoints.table.tableName,
          ),
        )
        ->Promise.thenResolve(rows =>
          rows
          ->(Utils.magic: unknown => array<unknown>)
          ->Array.map(row => row->S.convertOrThrow(InternalTable.Checkpoints.dbSchema))
        ),
      queryEffectCache: (type input output, effect: Envio.effect<input, output>, ~scope) => {
        let effect = effect->(Utils.magic: Envio.effect<input, output> => Internal.effect)
        let tableName = Internal.EffectCache.toTableName(~effectName=effect.name, ~scope)
        sql
        ->Postgres.unsafe(PgStorage.makeLoadAllQuery(~pgSchema, ~tableName))
        ->(Utils.magic: promise<unknown> => promise<array<{"id": string, "output": JSON.t}>>)
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
      pg,
      stop,
      restart: async () => {
        // The previous run has to be quiet before the resumed one takes over the
        // shared persistence, else the two race against the same db.
        await stop()
        onIndexerStopped()
        await make(~reset=false)
      },
    }
  }

  let outcome = try {
    let indexer = await make(~reset=true)
    await body(indexer)
    None
  } catch {
  | exn => Some(exn)
  }

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
  for i in 0 to stops->Array.length - 1 {
    switch stops->Array.get(i) {
    | Some(stop) => await attempt(stop)
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
  | Some(database) => await attempt(() => TestClickHouse.drop(~database))
  | None => ()
  }
  for i in 0 to clients->Array.length - 1 {
    switch clients->Array.get(i) {
    | Some(sql) => await attempt(() => sql->Postgres.endSql)
    | None => ()
    }
  }

  switch (outcome, teardownFailure.contents) {
  | (Some(exn), _) => throw(exn)
  | (None, Some(exn)) => throw(exn)
  | (None, None) => ()
  }
}
