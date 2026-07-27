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
      },
      Transport.make(pinoFile),
    )
  | EcsConsoleMultistream =>
    makeMultiStreamLogger(~logFile=None, ~options=Some({...Pino.ECS.make(), base}))
  | EcsConsole =>
    make({
      ...Pino.ECS.make(),
      level: userLogLevel,
      customLevels: logLevels,
      base,
    })
  | FileOnly =>
    makeWithOptionsAndTransport(
      {
        customLevels: logLevels,
        level: defaultFileLogLevel,
        base,
      },
      Transport.make(pinoFile),
    )
  | ConsoleRaw => makeMultiStreamLogger(~logFile=None, ~options=Some({base: base}))
  | ConsolePretty => makeMultiStreamLogger(~logFile=None, ~options=Some({base: base}))
  | Both => makeMultiStreamLogger(~logFile=Some(logFilePath), ~options=Some({base: base}))
  }
}

let setLogLevel = (logger: t, level: Pino.logLevel) => {
  logger->setLevel(level)
}

let trace = (logger, params: 'a) => {
  logger.trace(params->createPinoMessage)
}
let debug = (logger, params: 'a) => {
  logger.debug(params->createPinoMessage)
}
let info = (logger, params: 'a) => {
  logger.info(params->createPinoMessage)
}
let warn = (logger, params: 'a) => {
  logger.warn(params->createPinoMessage)
}
let error = (logger, params: 'a) => {
  logger.error(params->createPinoMessage)
}
let errorWithExn = (logger, err, params: 'a) => {
  logger->Pino.errorExn(params->createPinoMessageWithError(err))
}

let fatal = (logger, params: 'a) => {
  logger.fatal(params->createPinoMessage)
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

let mergeParams: (Internal.logParams, option<'a>) => 'a = %raw(`(base, params) =>
  params === undefined ? base : {...base, ...params}`)

// Spread a shared context object into a log message. Used where a block of
// code emits several lines about the same subject; the fields are still
// written on every line instead of being bound to a child logger.
let withParams: (Internal.logParams, 'a) => 'a = %raw(`(base, message) => ({...base, ...message})`)

// Binds params for code we hand the logger to rather than call — a `Source.t`
// implementation logs from inside its own module, where the caller's query
// context isn't in scope and can't be spread per line. Everywhere the params
// are in scope, write them on the line instead.
let createChild = (~logger: t, ~params: 'a) => logger->child(params->createChildParams)

// Wrap a logger as the user-facing `context.log`, routing through the custom
// `u*` levels. `params` is the item context (built by the ecosystem) and is
// merged into every line, with the user's own params taking precedence.
let userLogger = (logger: t, ~params as itemParams: Internal.logParams): Envio.logger => {
  info: (message: string, ~params=?) =>
    logger->logAtLevel(#uinfo, message, ~params=itemParams->mergeParams(params)),
  debug: (message: string, ~params=?) =>
    logger->logAtLevel(#udebug, message, ~params=itemParams->mergeParams(params)),
  warn: (message: string, ~params=?) =>
    logger->logAtLevel(#uwarn, message, ~params=itemParams->mergeParams(params)),
  error: (message: string, ~params=?) =>
    logger->logAtLevel(#uerror, message, ~params=itemParams->mergeParams(params)),
  errorWithExn: (message: string, exn) =>
    logger->logAtLevel(
      #uerror,
      message,
      ~params=itemParams->mergeParams(Some({"err": exn->Utils.prettifyExn})),
    ),
}
