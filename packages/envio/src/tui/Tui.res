type t

type info = {
  blockUnit: string,
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
@send external print: (t, string) => bool = "print"
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

type consoleClass
type writableClass
@module("node:console") external consoleClass: consoleClass = "Console"
@module("node:stream") external writableClass: writableClass = "Writable"

// Sends everything written through `console` above the display, the way the
// terminal would have shown it, and returns the function that restores it.
// Routed through a `Console` of our own so every method formats as Node's
// would; stderr stays where it is when it isn't the terminal, and once the
// display is gone, output goes back to where it came from.
let redirectConsole: (
  consoleClass,
  writableClass,
  string => bool,
) => unit => unit = %raw(`(Console, Writable, print) => {
  let original = [];
  const restore = () => original.forEach(([name, method]) => { console[name] = method; });
  const toDisplay = (stream) => new Writable({
    write(chunk, _encoding, callback) {
      // Each call ends its output with a newline, which printing a line adds.
      if (!print(chunk.toString().replace(/\n$/, ""))) {
        restore();
        stream.write(chunk);
      }
      callback();
    },
  });
  const redirected = new Console({
    stdout: toDisplay(process.stdout),
    stderr: process.stderr.isTTY ? toDisplay(process.stderr) : process.stderr,
    colorMode: process.stdout.hasColors(),
  });
  const methods = Object.keys(console).filter((name) => typeof redirected[name] === "function");
  original = methods.map((name) => [name, console[name]]);
  methods.forEach((name) => { console[name] = redirected[name].bind(redirected); });
  return restore;
}`)

let start = (~config: Config.t, ~getMetrics: unit => Metrics.t) => {
  let metrics = getMetrics()
  let info = {
    blockUnit: switch config.ecosystem.name {
    | Svm => "Slot"
    | Evm | Fuel => "Block"
    },
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
    Logging.warn({
      "msg": "Failed to start the TUI. Continuing without it.",
      "err": exn->Utils.prettifyExn,
    })
  | tui =>
    let restoreConsole = redirectConsole(consoleClass, writableClass, text => tui->print(text))
    let update = () => tui->update(getMetrics().chains->Array.map(toChain))
    update()
    let _ = setInterval(update, 500)
    let finish = () => {
      tui->stop
      restoreConsole()
    }
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
        Logging.error({
          "msg": "Failed to load messages from envio server",
          "err": exn->Utils.prettifyExn,
        })
        tui->setMessages(Null.Null)
      }
    )
    ->ignore
  }
}
