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
  logger.errorWithExn(. error, message->createPinoMessage)
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
  logger.errorWithExn(. error, params->createPinoMessage)
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

// // TODO: set ethers and postgres log levels in a similar way
// // TODO: use environment varibles to set log levels
/*
// Testing usage:
trace("By default - This trace message should only be seen in the log file.")
debug("By default - This debug message should only be seen in the log file.")

Js.log2("this is a summary of the available log levels", logger->levels)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
trace("This is an trace message.")
debug("This is a debug message.")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal(("This is a fatal message.", "another"))

setLogLevel(#debug)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message.")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#info)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

@send external userDebug: (Pino.t, 'a) => unit = "userDebug"
@send external userInfo: (Pino.t, 'a) => unit = "userInfo"
@send external userWarn: (Pino.t, 'a) => unit = "userWarn"
@send external userError: (Pino.t, 'a) => unit = "userError"
setLogLevel(#userDebug)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
let childLogger = createChild(~params={"child": "userLogs debug"})
// Js.log(childLogger)
childLogger->userDebug({"message": "This is a user debug message."})
childLogger->userInfo({"message": "This is a user info message."})
childLogger->userWarn({"message": "This is a user warn message."})
childLogger->userError({"message": "This is a user error message."})
setLogLevel(#userInfo)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
let childLogger = createChild(~params={"child": "userLogs info"})
childLogger->userDebug({"message": "This is a user debug message."})
childLogger->userInfo({"message": "This is a user info message."})
childLogger->userWarn({"message": "This is a user warn message."})
childLogger->userError({"message": "This is a user error message."})
setLogLevel(#userWarn)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
let childLogger = createChild(~params={"child": "userLogs warn"})
childLogger->userDebug({"message": "This is a user debug message."})
childLogger->userInfo({"message": "This is a user info message."})
childLogger->userWarn({"message": "This is a user warn message."})
childLogger->userError({"message": "This is a user error message."})
setLogLevel(#userError)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
let childLogger = createChild(~params={"child": "userLogs error"})
childLogger->userDebug({"message": "This is a user debug message."})
childLogger->userInfo({"message": "This is a user info message."})
childLogger->userWarn({"message": "This is a user warn message."})
childLogger->userError({"message": "This is a user error message."})

setLogLevel(#warn)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message. (should not be printed)")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#error)
Js.log(`Current log level: ${(logger->getLevel :> string)}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message. (should not be printed)")
warn("This is a warning message. (should not be printed)")
error("This is an error message.")
fatal("This is a fatal message.")

// Logging also works with objects of all shapes and sizes
fatal({
  "this": "is",
  "a": "fatal",
  "message": "object",
  "with": {
    "nested": "objects",
    "and": {"arrays": ["of", "things"]},
    "additionally": {"numbers": 0.5654},
  },
})
*/
