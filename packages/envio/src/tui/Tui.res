type t

type info = {
  ecosystem: string,
  version: string,
  projectDir: string,
  startTime: float,
  graphqlUrl: string,
  graphqlPassword: option<string>,
  devConsoleUrl: option<string>,
  clickhouseUrl: option<string>,
}

type chain = {
  chainId: string,
  poweredByHyperSync: bool,
  startBlock: int,
  endBlock: option<int>,
  firstEventBlockNumber: option<int>,
  progressBlockNumber: int,
  latestFetchedBlockNumber: int,
  knownHeight: int,
  sourceBlockNumber: int,
  timestampCaughtUpToHeadOrEndblock: option<float>,
  numEventsProcessed: float,
  rateLimitTimeMs: float,
  rateLimitResetInMs: option<float>,
  processedToEndblock: bool,
}

@send external make: (Core.tuiCtor, info) => t = "start"
@send external update: (t, array<chain>) => unit = "update"
@send external setMessages: (t, Null.t<array<InitApi.message>>) => unit = "setMessages"
@send external stop: t => unit = "stop"

// Whether this process draws the progress display: `ENVIO_TUI` first, then
// whether anything is watching. A supervisor asks the same question its
// workers would have, since it is the one drawing for the run.
let shouldUse = (~suppressed=false, ~explicitTui=Env.tuiEnvVar) =>
  switch (suppressed, explicitTui) {
  | (true, _) => false
  | (_, Some(tui)) => tui
  | (_, None) => !Envio.isNonInteractive()
  }

let toChain = (m: Metrics.chainMetrics): chain => {
  chainId: m.chainId->ChainId.toString,
  poweredByHyperSync: m.poweredByHyperSync,
  startBlock: m.startBlock,
  endBlock: m.endBlock,
  firstEventBlockNumber: m.firstEventBlockNumber,
  progressBlockNumber: m.progressBlockNumber,
  latestFetchedBlockNumber: m.latestFetchedBlockNumber,
  knownHeight: m.knownHeight,
  sourceBlockNumber: m.sourceBlockNumber,
  timestampCaughtUpToHeadOrEndblock: m.timestampCaughtUpToHeadOrEndblock->Option.map(Date.getTime),
  numEventsProcessed: m.numEventsProcessed,
  rateLimitTimeMs: m.rateLimitTimeMs,
  rateLimitResetInMs: m.rateLimitResetInMs,
  processedToEndblock: m->Metrics.hasProcessedToEndblock,
}

let drive = (tui: t, ~getMetrics: unit => Metrics.t) => {
  let update = () => tui->update(getMetrics().chains->Array.map(toChain))
  update()
  let interval = setInterval(update, 500)
  () => {
    clearInterval(interval)
    // The frame it stops on stays on screen, so it can't be a poll behind.
    update()
    tui->stop
  }
}

let start = (~config: Config.t, ~logger, ~getMetrics: unit => Metrics.t) => {
  let metrics = getMetrics()
  let info = {
    ecosystem: (config.ecosystem.name :> string),
    version: Utils.EnvioPackage.value.version,
    projectDir: NodeJs.Process.cwd(),
    startTime: metrics.startTime->Date.getTime,
    graphqlUrl: Env.Hasura.url,
    graphqlPassword: Env.Hasura.secret === "testing" ? Some("testing") : None,
    devConsoleUrl: config.isDev ? Some(`${Env.envioAppUrl}/console`) : None,
    clickhouseUrl: switch (config.storage.clickhouse, Env.ClickHouse.host()) {
    | (true, Some(host)) => Some(`${host}/play`)
    | _ => None
    },
  }
  switch Core.getAddon().tui->make(info) {
  | exception exn =>
    logger->Logger.warn(
      "Failed to start the TUI. Continuing without it.",
      ~params={"err": exn->Utils.prettifyExn},
    )
  | tui =>
    let finish = tui->drive(~getMetrics)
    NodeJs.Process.onExit(finish)
    // A signal nothing else listens for ends the process without an `exit`
    // event, so the display finishes first and the signal is raised again
    // once its default action is back.
    ["SIGINT", "SIGTERM", "SIGHUP"]->Array.forEach(signal => {
      let rec onSignal = () =>
        if NodeJs.Process.listenerCount(signal) === 1 {
          finish()
          NodeJs.Process.offSignal(signal, onSignal)
          NodeJs.Process.kill(NodeJs.Process.pid, signal)->ignore
        }
      NodeJs.Process.onSignal(signal, onSignal)
    })
    InitApi.getMessages(~config)
    ->Promise.thenResolve(result =>
      switch result {
      | Ok(messages) => tui->setMessages(Null.Value(messages))
      | Error(exn) =>
        logger->Logger.error(
          "Failed to load messages from envio server",
          ~params={"err": exn->Utils.prettifyExn},
        )
        tui->setMessages(Null.Null)
      }
    )
    ->ignore
  }
}
