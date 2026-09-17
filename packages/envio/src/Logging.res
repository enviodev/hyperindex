open Pino

type logStrategyType =
  | @as("ecs-file") EcsFile
  | @as("ecs-console") EcsConsole
  | @as("ecs-console-multistream") EcsConsoleMultistream
  | @as("file-only") FileOnly
  | @as("console-raw") ConsoleRaw
  | @as("console-pretty") ConsolePretty
  | @as("both-prettyconsole") Both

let logLevels = [
  // custom levels
  ("udebug", 32),
  ("uinfo", 34),
  ("uwarn", 36),
  ("uerror", 38),
  // Default levels
  ("trace", 10),
  ("debug", 20),
  ("info", 30),
  ("warn", 40),
  ("error", 50),
  ("fatal", 60),
]->Dict.fromArray

%%private(let logger = ref(None))

// Fields every line this process logs carries. Merged into each line rather
// than bound to a child logger: pino writes a child's bindings and the line's
// own fields side by side, so a line that names the same key would carry it
// twice. A fresh object per line, since pino merges the line's fields into
// whatever this returns.
%%private(let context: ref<dict<JSON.t>> = ref(Dict.make()))
%%private(let mixin = () => JSON.Object(context.contents->Dict.copy))

// A child logger that binds a field the process already carries would have pino
// write it twice: a child's bindings and the context are concatenated into the
// line, not merged. The context is the one place a line names it, which it can
// be because a process only takes one when its every line is about that chain.
%%private(
  let withoutContext = (params: 'a) =>
    switch context.contents->Dict.keysToArray {
    | [] => params
    | keys => {
        let narrowed = params->(Utils.magic: 'a => dict<JSON.t>)->Dict.copy
        keys->Array.forEach(key => narrowed->Dict.delete(key))
        narrowed->(Utils.magic: dict<JSON.t> => 'a)
      }
    }
)

let makeLogger = (~logStrategy, ~logFilePath, ~defaultFileLogLevel, ~userLogLevel) => {
  // Currently unused - useful if using multiple transports.
  // let pinoRaw = {"target": "pino/file", "level": Config.userLogLevel}
  let pinoFile: Transport.transportTarget = {
    target: "pino/file",
    options: {
      "destination": logFilePath,
      "append": true,
      "mkdir": true,
    }->Transport.makeTransportOptions,
    level: defaultFileLogLevel,
  }

  let makeMultiStreamLogger = MultiStreamLogger.make(
    ~userLogLevel,
    ~defaultFileLogLevel,
    ~customLevels=logLevels,
    ...
  )

  // Empty base disables pid and hostname in logs
  let base: JSON.t = %raw("{}")

  switch logStrategy {
  | EcsFile =>
    makeWithOptionsAndTransport(
      {
        ...Pino.ECS.make(),
        customLevels: logLevels,
        base,
        mixin,
      },
      Transport.make(pinoFile),
    )
  | EcsConsoleMultistream =>
    makeMultiStreamLogger(~logFile=None, ~options=Some({...Pino.ECS.make(), base, mixin}))
  | EcsConsole =>
    make({
      ...Pino.ECS.make(),
      level: userLogLevel,
      customLevels: logLevels,
      base,
      mixin,
    })
  | FileOnly =>
    makeWithOptionsAndTransport(
      {
        customLevels: logLevels,
        level: defaultFileLogLevel,
        base,
        mixin,
      },
      Transport.make(pinoFile),
    )
  | ConsoleRaw => makeMultiStreamLogger(~logFile=None, ~options=Some({base, mixin}))
  | ConsolePretty => makeMultiStreamLogger(~logFile=None, ~options=Some({base, mixin}))
  | Both => makeMultiStreamLogger(~logFile=Some(logFilePath), ~options=Some({base, mixin}))
  }
}

let setLogger = l => {
  logger := Some(l)
}

let getLogger = () => {
  switch logger.contents {
  | Some(logger) => logger
  | None => JsError.throwWithMessage("Unreachable code. Logger not initialized")
  }
}

let setLogLevel = (level: Pino.logLevel) => {
  getLogger()->setLevel(level)
}

let trace = message => {
  getLogger().trace(message->createPinoMessage)
}

let debug = message => {
  getLogger().debug(message->createPinoMessage)
}

let info = message => {
  getLogger().info(message->createPinoMessage)
}

let warn = message => {
  getLogger().warn(message->createPinoMessage)
}

let error = message => {
  getLogger().error(message->createPinoMessage)
}
let errorWithExn = (error, message) => {
  getLogger()->Pino.errorExn(message->createPinoMessageWithError(error))
}

let fatal = message => {
  getLogger().fatal(message->createPinoMessage)
}

let childTrace = (logger, params: 'a) => {
  logger.trace(params->createPinoMessage)
}
let childDebug = (logger, params: 'a) => {
  logger.debug(params->createPinoMessage)
}
let childInfo = (logger, params: 'a) => {
  logger.info(params->createPinoMessage)
}
let childWarn = (logger, params: 'a) => {
  logger.warn(params->createPinoMessage)
}
let childError = (logger, params: 'a) => {
  logger.error(params->createPinoMessage)
}
let childErrorWithExn = (logger, error, params: 'a) => {
  logger->Pino.errorExn(params->createPinoMessageWithError(error))
}

let childFatal = (logger, params: 'a) => {
  logger.fatal(params->createPinoMessage)
}

let createChild = (~params: 'a) => {
  getLogger()->child(params->withoutContext->createChildParams)
}

// What belongs on every line is the run's to decide; the logger only carries
// what it is handed. A line that names one of these fields itself wins.
let setContext = (fields: dict<JSON.t>) => context := fields

let createChildFrom = (~logger: t, ~params: 'a) => {
  logger->child(params->withoutContext->createChildParams)
}

@inline
let logAtLevel = (logger: t, level: Pino.logLevel, message: string, ~params=?) => {
  (
    logger
    ->(Utils.magic: t => dict<(option<'a>, string) => unit>)
    ->Dict.getUnsafe((level :> string))
  )(params, message)
}

let noopLogger: Envio.logger = {
  info: (_message: string, ~params as _=?) => (),
  debug: (_message: string, ~params as _=?) => (),
  warn: (_message: string, ~params as _=?) => (),
  error: (_message: string, ~params as _=?) => (),
  errorWithExn: (_message: string, _exn) => (),
}

// Wrap a (child) logger as the user-facing `context.log`, routing through the
// custom `u*` levels. The caller builds the per-item logger via the ecosystem.
let userLogger = (logger: t): Envio.logger => {
  info: (message: string, ~params=?) => logger->logAtLevel(#uinfo, message, ~params?),
  debug: (message: string, ~params=?) => logger->logAtLevel(#udebug, message, ~params?),
  warn: (message: string, ~params=?) => logger->logAtLevel(#uwarn, message, ~params?),
  error: (message: string, ~params=?) => logger->logAtLevel(#uerror, message, ~params?),
  errorWithExn: (message: string, exn) =>
    logger->logAtLevel(#uerror, message, ~params={"err": exn->Utils.prettifyExn}),
}
