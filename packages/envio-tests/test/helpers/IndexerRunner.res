type metric = {
  value: string,
  labels: dict<string>,
}

// The schema this indexer's tables live in, and the run's own client — closed
// with it. A test needing raw SQL should reach for these rather than opening a
// client the run won't clean up.
type pg = {sql: Postgres.sql, pgSchema: string}

// Which persistence a run is exercised against. Postgres either way — the
// ClickHouse leg indexes the same scenario with the sink switched on.
type backend = [#postgres | #clickhouse]

let backendName = (backend: backend) =>
  switch backend {
  | #postgres => "postgres"
  | #clickhouse => "clickhouse"
  }

let selectedBackend: backend = switch %raw(`process.env.ENVIO_TEST_STORAGE`)->Nullable.toOption {
| None | Some("") => #postgres
| Some("postgres") => #postgres
| Some("clickhouse") => #clickhouse
| Some(other) =>
  JsError.throwWithMessage(
    `Unknown ENVIO_TEST_STORAGE value "${other}". Expected postgres or clickhouse.`,
  )
}

type rec t = {
  // Resolves once the indexer has run every scheduled step to completion and
  // can only move again when the outside world answers. Nothing to count in
  // ticks: the loop reports its own in-flight work.
  //
  // "The outside world answers" covers the poll a chain at its head is parked
  // on between rounds, so a settled indexer isn't always one with a query
  // waiting to be answered. An assertion that the pending set is empty needs
  // `settleUntil` or `Scenario.waitQuery` to pin down which side of that poll
  // it is on; a settle alone would read the gap between two polls as the
  // answer. A retry's backoff is not in that category — the loop is biding its
  // time before asking again, and settle waits it out.
  settle: unit => promise<unit>,
  // Settles, then keeps settling until the condition holds — for state that
  // only arrives once a polling interval elapses. `message` names what was
  // being waited for when it never does.
  settleUntil: (unit => bool, ~message: string) => promise<unit>,
  // Wraps a wait the test itself holds closed — a gate inside a handler, say —
  // so the loop reads as parked on the test rather than as working. Without it
  // `settle` would wait out a block only the test can lift.
  //
  // It discounts one unit of scheduled work, so it is only valid where the
  // scheduler is counting one, and only one park at a time: the whole
  // processing run counts as a single unit, not each of the handlers and
  // contract registers running concurrently inside it, so two gates held open
  // at once discount it twice over. Not from a test body either, and not from
  // the write loop's own calls (`writeBatch`, `setChainMeta`) — those run off
  // the scheduler, and `settle` covers them through the flush instead.
  //
  // Used anywhere else it puts the count into deficit, which `settle` reports
  // by name rather than sitting on. That report is the check: the count says
  // nothing about whether this particular caller had a unit to discount.
  park: 'a. (unit => promise<'a>) => promise<'a>,
  waitUntilReady: unit => promise<unit>,
  // Batches processed but not yet written. A test that stalls a write watches
  // this to see the next batch queue up behind it.
  queuedWrites: unit => int,
  query: 'entity. string => promise<array<'entity>>,
  queryHistory: 'entity. string => promise<array<Change.t<'entity>>>,
  queryRaw: 'entity. Internal.entityConfig => promise<array<'entity>>,
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
    let pg = {sql, pgSchema}
    let storage = mapStorage(
      // Tracking tables in Hasura costs ~1.9 seconds per indexer.
      PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false),
    )
    let persistence = PgStorage.makePersistenceFromConfig(~config, ~storage)

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
    // Before the loop starts asking: a mock call parked before the hand-off
    // would count as work for as long as it waits.
    MockSource.installMockSourcePark(~config, ~park=work => state->IndexerState.suspendInFlight(work))
    state->IndexerLoop.start

    // One macrotask hop, which drains every pending microtask behind it.
    let drainTick = () => Promise.make((resolve, _) => NodeJs.setImmediate(() => resolve()))

    // Well under vitest's own 30s: a settle that never comes back should say
    // what the loop was still doing, rather than surfacing as a bare test
    // timeout — but a flush against a real database can take seconds that have
    // nothing wrong with them, so the bound is generous.
    let settleTimeoutMs = 15_000

    // The budget a `settleUntil` gets for all its rounds together, settling
    // included. Also under vitest's, so its message about the condition is what
    // a test sees rather than a bare timeout.
    let settleUntilTimeoutMs = 20_000.

    // Runs until the loop has nothing left to do on its own. `whenIdle` alone
    // isn't enough twice over: a source response that resolved this tick hasn't
    // reached its handler yet (the parked frame only rejoins the count when it
    // resumes), and the write loop is driven by the store rather than by the
    // scheduler. Draining the tick settles the first, `flush` the second, and
    // the re-check catches whatever either of them started. `timedOut` stops the
    // recursion once the caller has given up, so a wedged run doesn't keep
    // driving the store for the rest of the worker.
    // Nothing downstream can be trusted once the count has gone into deficit,
    // and waiting the bound out would only delay saying so.
    let throwOnDeficit = () =>
      if state->IndexerState.hasInFlightDeficit {
        JsError.throwWithMessage(
          "The indexer's in-flight count went into deficit: either a fan-out counted once for work that runs many times over, or an `indexer.park` from a frame the scheduler wasn't counting.",
        )
      }

    let rec settleLoop = async (~timedOut) => {
      // `whenIdle` returns at once on a latched deficit rather than waiting for
      // an idle reading that can never come, so this catches one that predates
      // the settle as well as one that lands during it.
      await state->IndexerState.whenIdle
      throwOnDeficit()
      await drainTick()
      // Checked before the flush, not just after: the run's teardown drops the
      // schema once the caller has given up, and a write started here would
      // land on a schema that no longer exists.
      if !timedOut.contents {
        await state->Writing.flush
        // Re-checked before deciding this round settled anything: a deficit
        // that latched during the drain or the flush makes `inFlight > 0` read
        // as quiet for a count that is anything but.
        throwOnDeficit()
        if (
          !timedOut.contents &&
          (state->IndexerState.inFlight > 0 || state->IndexerState.writeFiber->Option.isSome)
        ) {
          await settleLoop(~timedOut)
        }
      }
    }

    let settleWithin = async (~timeoutMs) => {
      let timeoutId = ref(None)
      let timedOut = ref(false)
      // Cleared whichever way the race ends: a timer left running holds the
      // vitest worker's event loop open for its whole span.
      let failure = try {
        await Promise.race([
          settleLoop(~timedOut),
          Promise.make((resolve, _) => {
            timeoutId := Some(setTimeout(() => {
                timedOut := true
                resolve()
              }, timeoutMs))
          }),
        ])
        None
      } catch {
      | exn => Some(exn)
      }
      timeoutId.contents->Option.forEach(clearTimeout)
      switch failure {
      | Some(exn) => throw(exn)
      | None => ()
      }
      if timedOut.contents {
        let busy =
          [
            state->IndexerState.inFlight > 0
              ? Some(`${state->IndexerState.inFlight->Int.toString} scheduled step(s)`)
              : None,
            // Reachable when the timer wins the race: the loop's own report of
            // the deficit is discarded with it.
            state->IndexerState.hasInFlightDeficit
              ? Some("a count in deficit — see `indexer.park`'s contract")
              : None,
            state->IndexerState.isProcessing ? Some("a batch being processed") : None,
            state->IndexerState.writeFiber->Option.isSome ? Some("a write") : None,
          ]->Array.filterMap(x => x)
        JsError.throwWithMessage(
          `Timed out waiting for the indexer to settle, still in flight: ${switch busy {
            | [] => "nothing — the loop settled and started again"
            | busy => busy->Array.join(", ")
            }}. Either the loop is genuinely still working — a retry's backoff, a rate-limit reset — or a wait the test itself holds closed needs to go through \`indexer.park\`, which the settle otherwise sits and waits out.`,
        )
      }
    }

    let settle = () => settleWithin(~timeoutMs=settleTimeoutMs)

    // Settles, then keeps settling until `predicate` holds, waiting on the
    // clock between rounds for conditions that only arrive once a polling
    // interval elapses. Every round draws on one budget, settling included, so
    // a condition that never comes says what it was waiting for rather than
    // stacking two settle bounds past the suite's own timeout.
    let rec settleUntil = async (predicate, ~message, ~deadline) => {
      let remaining = deadline -. Date.now()
      // A sliver of budget left is the condition never arriving, not a settle
      // worth starting — and a settle given no time reports its own timeout
      // instead of what was being waited for. Checked once more first: the
      // condition may have arrived during the wait that used the budget up.
      if remaining < 100. {
        if !predicate() {
          JsError.throwWithMessage(`Timed out waiting for ${message}`)
        }
      } else {
        await settleWithin(
          ~timeoutMs=Pervasives.min(settleTimeoutMs->Int.toFloat, remaining)->Float.toInt,
        )
        if !predicate() {
          await Utils.delay(1)
          await settleUntil(predicate, ~message, ~deadline)
        }
      }
    }
    let settleUntil = (predicate, ~message) =>
      settleUntil(predicate, ~message, ~deadline=Date.now() +. settleUntilTimeoutMs)

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
            // The resume-time index repair runs off the loop, so nothing above
            // waits for it; its DDL would otherwise land on the dropped schema.
            switch state->IndexerState.repairFiber {
            | Some(fiber) => await fiber
            | None => ()
            }
          }
        )()
        stopped := Some(promise)
        promise
      }
    stops->Array.push(stop)->ignore

    // Rows come back decoded, parsed with the table's own field schemas, so an
    // assertion reads the entity rather than its storage encoding.
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
              Float.compare(
                a->Change.getCheckpointId->BigInt.toFloat,
                b->Change.getCheckpointId->BigInt.toFloat,
              )
            | order => order
            }
          })
        })

    {
      settle,
      settleUntil,
      park: work => state->IndexerState.suspendInFlight(work),
      queuedWrites: () => state->IndexerState.processedBatches->Array.length,
      waitUntilReady: () =>
        settleUntil(
          () =>
            state
            ->IndexerState.chainStates
            ->Dict.valuesToArray
            ->Array.every(chainState => chainState->ChainState.isReady),
          ~message="the indexer to report ready",
        ),
      query: (type entity, name) =>
        queryEntity(config->entityConfigByName(name))->(
          Utils.magic: promise<array<unknown>> => promise<array<entity>>
        ),
      queryRaw: (type entity, entityConfig: Internal.entityConfig) =>
        queryEntity(entityConfig)->(
          Utils.magic: promise<array<unknown>> => promise<array<entity>>
        ),
      queryHistory: (type entity, name) =>
        queryEntityHistory(config->entityConfigByName(name))->(
          Utils.magic: promise<array<Change.t<Internal.entity>>> => promise<array<Change.t<entity>>>
        ),
      queryCheckpoints: () =>
        sql
        ->Postgres.unsafe(
          PgStorage.makeLoadAllQuery(~pgSchema, ~tableName=InternalTable.Checkpoints.table.tableName),
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
