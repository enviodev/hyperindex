// NOTE: this is a file for SystemLogs, not UserLogs.
// TODO: This file shouldn't be exposed to users in our external interface.
open Pino

type pinoTransportConfig

let makePinoConfig: 'a => pinoTransportConfig = Obj.magic

let pinoPretty = {"target": "pino-pretty", "level": Config.userLogLevel}->makePinoConfig
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
})

let pinoOptions = if Config.useEcsFormat {
  {
    ...Pino.ECS.make(),
    customLevels: [
      ("userDebug", 32),
      ("userInfo", 34),
      ("userWarn", 36),
      ("userError", 38),
    ]->Js.Dict.fromArray,
  }
} else {
  {
    customLevels: [
      ("userDebug", 32),
      ("userInfo", 34),
      ("userWarn", 36),
      ("userError", 38),
    ]->Js.Dict.fromArray,
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
@send external userDebug: (Pino.t, 'a) => unit = "userDebug"
@send external userInfo: (Pino.t, 'a) => unit = "userInfo"
@send external userWarn: (Pino.t, 'a) => unit = "userWarn"
@send external userError: (Pino.t, 'a) => unit = "userError"
