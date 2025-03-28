// NOTE: this is a file for SystemLogs, not UserLogs.
// TODO: This file shouldn't be exposed to users in our external interface.
open Pino

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

// let pinoPretty: Transport.transportTarget = {
//   target: "pino-pretty",
//   level: Env.userLogLevel, // NOTE: - this log level only is used if this transport is running in its own worker (ie there are multiple transports), otherwise it is overridden by the top level config.
//   options: {
//     "customLevels": logLevels,
//     "sync": true,
//     /// NOTE: the lables have to be lower case! (pino pretty doesn't recognise them if there are upper case letters)
//     /// https://www.npmjs.com/package/colorette#supported-colors - these are available colors
//     "customColors": "fatal:bgRed,error:red,warn:yellow,info:green,udebug:bgBlue,uinfo:bgGreen,uwarn:bgYellow,uerror:bgRed,debug:blue,trace:gray",
//   }->Transport.makeTransportOptions,
// }
// Currently unused - useful if using multiple transports.
// let pinoRaw = {"target": "pino/file", "level": Config.userLogLevel}
let pinoFile: Transport.transportTarget = {
  target: "pino/file",
  options: {
    "destination": Env.logFilePath,
    "append": true,
    "mkdir": true,
  }->Transport.makeTransportOptions,
  level: Env.defaultFileLogLevel,
}

let makeMultiStreamLogger =
  MultiStreamLogger.make(
    ~userLogLevel=Env.userLogLevel,
    ~defaultFileLogLevel=Env.defaultFileLogLevel,
    ~customLevels=logLevels,
    ...
  )

let logger = switch Env.logStrategy {
| EcsFile =>
  makeWithOptionsAndTransport(
    {
      ...Pino.ECS.make(),
      customLevels: logLevels,
    },
    Transport.make(pinoFile),
  )
| EcsConsoleMultistream => makeMultiStreamLogger(~logFile=None, ~options=Some(Pino.ECS.make()))
| EcsConsole =>
  make({
    ...Pino.ECS.make(),
    level: Env.userLogLevel,
    customLevels: logLevels,
  })
| FileOnly =>
  makeWithOptionsAndTransport(
    {
      customLevels: logLevels,
      level: Env.defaultFileLogLevel,
    },
    Transport.make(pinoFile),
  )
| ConsoleRaw => makeMultiStreamLogger(~logFile=None, ~options=None)
| ConsolePretty => makeMultiStreamLogger(~logFile=None, ~options=None)
| Both => makeMultiStreamLogger(~logFile=Some(Env.logFilePath), ~options=None)
}

let setLogLevel = (level: Pino.logLevel) => {
  logger->setLevel(level)
}

let trace = message => {
  logger.trace(message->createPinoMessage)
}

let debug = message => {
  logger.debug(message->createPinoMessage)
}

let info = message => {
  logger.info(message->createPinoMessage)
}

let warn = message => {
  logger.warn(message->createPinoMessage)
}

let error = message => {
  logger.error(message->createPinoMessage)
}
let errorWithExn = (error, message) => {
  logger->Pino.errorExn(message->createPinoMessageWithError(error))
}

let fatal = message => {
  logger.fatal(message->createPinoMessage)
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
  logger->child(params->createChildParams)
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
