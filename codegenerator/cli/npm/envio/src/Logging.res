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
]->Js.Dict.fromArray

%%private(let logger = ref(None))

let setLogger = (~logStrategy, ~logFilePath, ~defaultFileLogLevel, ~userLogLevel) => {
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

  let makeMultiStreamLogger =
    MultiStreamLogger.make(~userLogLevel, ~defaultFileLogLevel, ~customLevels=logLevels, ...)

  logger :=
    Some(
      switch logStrategy {
      | EcsFile =>
        makeWithOptionsAndTransport(
          {
            ...Pino.ECS.make(),
            customLevels: logLevels,
          },
          Transport.make(pinoFile),
        )
      | EcsConsoleMultistream =>
        makeMultiStreamLogger(~logFile=None, ~options=Some(Pino.ECS.make()))
      | EcsConsole =>
        make({
          ...Pino.ECS.make(),
          level: userLogLevel,
          customLevels: logLevels,
        })
      | FileOnly =>
        makeWithOptionsAndTransport(
          {
            customLevels: logLevels,
            level: defaultFileLogLevel,
          },
          Transport.make(pinoFile),
        )
      | ConsoleRaw => makeMultiStreamLogger(~logFile=None, ~options=None)
      | ConsolePretty => makeMultiStreamLogger(~logFile=None, ~options=None)
      | Both => makeMultiStreamLogger(~logFile=Some(logFilePath), ~options=None)
      },
    )
}

let getLogger = () => {
  switch logger.contents {
  | Some(logger) => logger
  | None => Js.Exn.raiseError("Unreachable code. Logger not initialized")
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
  getLogger()->child(params->createChildParams)
}
let createChildFrom = (~logger: t, ~params: 'a) => {
  logger->child(params->createChildParams)
}

let getUserLogger = {
  @inline
  let log = (logger: Pino.t, level: Pino.logLevelUser, message: string, ~params) => {
    (logger->Utils.magic->Js.Dict.unsafeGet((level :> string)))(params, message)
  }

  (logger): Envio.logger => {
    info: (message: string, ~params=?) => logger->log(#uinfo, message, ~params),
    debug: (message: string, ~params=?) => logger->log(#udebug, message, ~params),
    warn: (message: string, ~params=?) => logger->log(#uwarn, message, ~params),
    error: (message: string, ~params=?) => logger->log(#uerror, message, ~params),
    errorWithExn: (message: string, exn) =>
      logger->log(#uerror, message, ~params={"err": exn->Internal.prettifyExn}),
  }
}
