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

let pinoPretty: Transport.transportTarget = {
  target: "pino-pretty",
  level: Config.userLogLevel, // NOTE: - this log level only is used if this transport is running in its own worker (ie there are multiple transports), otherwise it is overridden by the top level config.
  options: {
    "customLevels": logLevels,
    /// NOTE: the lables have to be lower case! (pino pretty doesn't recognise them if there are upper case letters)
    /// https://www.npmjs.com/package/colorette#supported-colors - these are available colors
    "customColors": "fatal:bgRed,error:red,warn:yellow,info:green,udebug:bgBlue,uinfo:bgGreen,uwarn:bgYellow,uerror:bgRed,debug:blue,trace:gray",
  }->Transport.makeTransportOptions,
}
// Currently unused - useful if using multiple transports.
// let pinoRaw = {"target": "pino/file", "level": Config.userLogLevel}
let pinoFile: Transport.transportTarget = {
  target: "pino/file",
  options: {
    "destination": Config.logFilePath,
    "append": true,
    "mkdir": true,
  }->Transport.makeTransportOptions,
  level: Config.defaultFileLogLevel,
}

let logger = switch Config.logStrategy {
| EcsFile =>
  makeWithOptionsAndTransport(
    {
      ...Pino.ECS.make(),
      customLevels: logLevels,
    },
    Transport.make(pinoFile),
  )
| EcsConsole =>
  make({
    ...Pino.ECS.make(),
    level: Config.userLogLevel,
    customLevels: logLevels,
  })
| FileOnly =>
  makeWithOptionsAndTransport(
    {
      customLevels: logLevels,
      level: Config.defaultFileLogLevel,
    },
    Transport.make(pinoFile),
  )
| ConsoleRaw =>
  make({
    customLevels: logLevels,
    level: Config.userLogLevel,
  })
| ConsolePretty =>
  makeWithOptionsAndTransport(
    {
      customLevels: logLevels,
      level: Config.userLogLevel, // Here this log level overrides the pino pretty log level config (since there is only 1 transport.)
    },
    Transport.make(pinoPretty),
  )
| Both =>
  makeWithOptionsAndTransport(
    {
      customLevels: logLevels,
      level: #trace, // This log level needs to be trace so that the pino pretty and file printing can have any log level.
    },
    Transport.make({targets: [pinoPretty, pinoFile]}),
  )
}

let setLogLevel = (level: Pino.logLevel) => {
  logger->setLevel(level)
}

let trace = message => {
  logger.trace(. message->createPinoMessage)
}

let debug = message => {
  logger.debug(. message->createPinoMessage)
}

let info = message => {
  logger.info(. message->createPinoMessage)
}

let warn = message => {
  logger.warn(. message->createPinoMessage)
}

let error = message => {
  logger.error(. message->createPinoMessage)
}
let errorWithExn = (error, message) => {
  logger->Pino.errorExn(error, message->createPinoMessage)
}

let fatal = message => {
  logger.fatal(. message->createPinoMessage)
}

let childTrace = (logger, params: 'a) => {
  logger.trace(. params->createPinoMessage)
}
let childDebug = (logger, params: 'a) => {
  logger.debug(. params->createPinoMessage)
}
let childInfo = (logger, params: 'a) => {
  logger.info(. params->createPinoMessage)
}
let childWarn = (logger, params: 'a) => {
  logger.warn(. params->createPinoMessage)
}
let childError = (logger, params: 'a) => {
  logger.error(. params->createPinoMessage)
}
let childErrorWithExn = (logger, error, params: 'a) => {
  logger->Pino.errorExn(error, params->createPinoMessage)
}
let childFatal = (logger, params: 'a) => {
  logger.fatal(. params->createPinoMessage)
}

let createChild = (~params: 'a) => {
  logger->child(params->createChildParams)
}
let createChildFrom = (~logger: t, ~params: 'a) => {
  logger->child(params->createChildParams)
}

// NOTE: these functions are used for the user logging, but they are exposed to the user only via the context and the `Logs.res` file.
@send external udebug: (Pino.t, 'a) => unit = "udebug"
@send external uinfo: (Pino.t, 'a) => unit = "uinfo"
@send external uwarn: (Pino.t, 'a) => unit = "uwarn"
@send external uerror: (Pino.t, 'a) => unit = "uerror"
@send external uerrorWithExn: (Pino.t, option<Js.Exn.t>, 'a) => unit = "uerror"
