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

let createChildFrom = (~logger: t, ~params: 'a) => {
  logger->child(params->createChildParams)
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
