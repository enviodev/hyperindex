// The indexer's own HTTP surface: metrics for a scraper, health for an
// orchestrator, and the console's view of the run. What it serves is handed to
// it, so one process's readings and a supervised group's merged ones render the
// same way.

// The public console/state chain shape. Kept to exactly this field set for
// backward compatibility with consumers like RACE — new metric fields stay off
// the HTTP response.
type chainData = {
  chainId: ChainId.t,
  poweredByHyperSync: bool,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  numEventsProcessed: float,
  latestFetchedBlockNumber: int,
  // Need this for API backwards compatibility
  @as("currentBlockHeight")
  knownHeight: int,
  numBatchesFetched: int,
  startBlock: int,
  endBlock: option<int>,
  numAddresses: int,
}
@tag("status")
type state =
  | @as("disabled") Disabled({})
  | @as("initializing") Initializing({})
  | @as("active")
  Active({
      envioVersion: string,
      chains: array<chainData>,
      indexerStartTime: Date.t,
      isPreRegisteringDynamicContracts: bool,
      rollbackOnReorg: bool,
    })

let toChainData = (m: Metrics.chainMetrics): chainData => {
  chainId: m.chainId,
  poweredByHyperSync: m.poweredByHyperSync,
  firstEventBlockNumber: m.firstEventBlockNumber,
  latestProcessedBlock: m.latestProcessedBlock,
  timestampCaughtUpToHeadOrEndblock: m.timestampCaughtUpToHeadOrEndblock,
  numEventsProcessed: m.numEventsProcessed,
  latestFetchedBlockNumber: m.latestFetchedBlockNumber,
  knownHeight: m.knownHeight,
  numBatchesFetched: m.numBatchesFetched,
  startBlock: m.startBlock,
  endBlock: m.endBlock,
  numAddresses: m.numAddresses,
}

let chainDataSchema = S.schema((s): chainData => {
  chainId: s.matches(ChainId.schema),
  poweredByHyperSync: s.matches(S.bool),
  firstEventBlockNumber: s.matches(S.option(S.int)),
  latestProcessedBlock: s.matches(S.option(S.int)),
  timestampCaughtUpToHeadOrEndblock: s.matches(S.option(S.datetime(S.string))),
  numEventsProcessed: s.matches(S.float),
  latestFetchedBlockNumber: s.matches(S.int),
  knownHeight: s.matches(S.int),
  numBatchesFetched: s.matches(S.int),
  startBlock: s.matches(S.int),
  endBlock: s.matches(S.option(S.int)),
  numAddresses: s.matches(S.int),
})
let stateSchema = S.union([
  S.literal(Disabled({})),
  S.literal(Initializing({})),
  S.schema(s => Active({
    envioVersion: s.matches(S.string),
    chains: s.matches(S.array(chainDataSchema)),
    indexerStartTime: s.matches(S.datetime(S.string)),
    // Keep the field, since Dev Console expects it to be present
    isPreRegisteringDynamicContracts: false,
    rollbackOnReorg: s.matches(S.bool),
  })),
])

// Runtime state lives in the process-wide `EnvioGlobal` record (shared
// across duplicate envio module instances); the slots are opaque there, so
// cast them to the real types here.
let startServer = (
  ~getMetrics: unit => option<Metrics.t>,
  ~envioVersion: string,
  ~onSyncCache: unit => promise<unit>,
  ~collectRuntime: unit => string,
  ~isDevelopmentMode: bool,
) => {
  open Express

  let app = make()

  let consoleCorsMiddleware = (req, res, next) => {
    switch req.headers->Dict.get("origin") {
    | Some(origin) if origin === Env.prodEnvioAppUrl || origin === Env.envioAppUrl =>
      res->setHeader("Access-Control-Allow-Origin", origin)
    | _ => ()
    }

    res->setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
    res->setHeader("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept")

    if req.method === Rest.Options {
      res->sendStatus(200)
    } else {
      next()
    }
  }
  app->useFor("/console", consoleCorsMiddleware)
  app->useFor("/metrics", consoleCorsMiddleware)
  app->useFor("/metrics/runtime", consoleCorsMiddleware)

  app->get("/healthz", (_req, res) => {
    // this is the machine readable port used in kubernetes to check the health of this service.
    //   aditional health information could be added in the future (info about errors, back-offs, etc).
    res->sendStatus(200)
  })

  app->get("/console/state", (_req, res) => {
    let state = if !isDevelopmentMode {
      Disabled({})
    } else {
      switch getMetrics() {
      | None => Initializing({})
      | Some(metrics) =>
        Active({
          envioVersion,
          chains: metrics.chains->Array.map(toChainData),
          indexerStartTime: metrics.startTime,
          isPreRegisteringDynamicContracts: false,
          rollbackOnReorg: metrics.rollbackEnabled,
        })
      }
    }

    res->json(state->S.reverseConvertToJsonOrThrow(stateSchema))
  })

  app->post("/console/syncCache", (_req, res) => {
    if isDevelopmentMode {
      onSyncCache()
      ->Promise.thenResolve(() => res->json(Boolean(true)))
      // A dump that couldn't be made, or couldn't be confirmed, answers the
      // same `false` a disabled console does. Leaving it unanswered would hold
      // the request open for as long as the indexer runs.
      ->Promise.catch(exn => {
        Logging.errorWithExn(exn, "Failed to sync the effect cache")
        res->json(Boolean(false))
        Promise.resolve()
      })
      ->Promise.ignore
    } else {
      res->json(Boolean(false))
    }
  })

  app->get("/metrics", (_req, res) => {
    res->set("Content-Type", Metrics.contentType)
    let _ = res->endWithData(Metrics.collect(~metrics=getMetrics()))
  })

  app->get("/metrics/runtime", (_req, res) => {
    res->set("Content-Type", Metrics.contentType)
    let _ = res->endWithData(collectRuntime())
  })

  let server = app->listen(Env.serverPort)
  server->Express.onError(err => {
    let code = (err->(Utils.magic: JsExn.t => {..}))["code"]
    if code === "EADDRINUSE" {
      Logging.error(
        `Port ${Env.serverPort->Int.toString} is already in use. To fix this either:` ++
        `\n  1. Kill the process using the port: lsof -ti :${Env.serverPort->Int.toString} | xargs kill -9` ++ `\n  2. Use a different port by setting the ENVIO_INDEXER_PORT environment variable: ENVIO_INDEXER_PORT=9899 envio start`,
      )
    } else {
      Logging.errorWithExn(err, "Failed to start indexer server")
    }
    NodeJs.process->NodeJs.exitWithCode(Failure)
  })
}
