// NOTE: this is a file for SystemLogs, not UserLogs.
// TODO: This file shouldn't be exposed to users in our external interface.
open Pino

type pinoTransportConfig

let makePinoConfig: 'a => pinoTransportConfig = Obj.magic

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

let pinoPretty = {
  "target": "pino-pretty",
  "level": Config.userLogLevel,
  "customColors": "fatal:bgRed,error:red,warn:yellow,info:green,udebug:bgBlue,uinfo:bgGreen,uwarn:bgYellow,uerror:bgRed,debug:blue,trace:gray",
  "options": {
    "customLevels": logLevels,
    /// NOTE: the lables have to be lower case! (pino pretty doesn't recognise them if there are upper case letters)
    /// https://www.npmjs.com/package/colorette#supported-colors - these are available colors
    "customColors": "fatal:bgRed,error:red,warn:yellow,info:green,udebug:bgBlue,uinfo:bgGreen,uwarn:bgYellow,uerror:bgRed,debug:blue,trace:gray",
  },
}->makePinoConfig
let pinoRaw = {"target": "pino/file", "level": Config.userLogLevel}->makePinoConfig
let pinoFile = {
  "target": "pino/file",
  "options": {"destination": Config.logFilePath, "append": true, "mkdir": true},
  "level": Config.defaultFileLogLevel,
}->makePinoConfig

let transport = Trasport.make({
  "targets": switch Config.logStrategy {
  | #fileOnly => [pinoFile]
  | #consoleRaw => [pinoRaw]
  | #consolePretty => [pinoPretty]
  | #both => [pinoFile, pinoPretty]
  },
  "levels": logLevels,
})

let pinoOptions = if Config.useEcsFormat {
  {
    ...Pino.ECS.make(),
    customLevels: logLevels,
  }
} else {
  {
    customLevels: logLevels,
  }
}
let logger = makeWithOptionsAndTransport(pinoOptions, transport)
let setLogLevel = (level: Pino.logLevel) => {
  logger->setLevel(level)
}
setLogLevel(Config.baseLogLevel)

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
  logger->Pino.errorWithExn(error, message->createPinoMessage)
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
  logger->Pino.errorWithExn(error, params->createPinoMessage)
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
@send external uerrorWithExn: (Pino.t, exn, 'a) => unit = "uerror"
