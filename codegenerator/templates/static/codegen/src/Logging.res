open Pino

type pinoTransportConfig

let makePinoConfig: 'a => pinoTransportConfig = Obj.magic

let transport = Trasport.make({
  "targets": [
    {
      "target": "pino/file",
      "options": {"destination": Config.logFilePath, "append": true, "mkdir": true},
      "level": Config.defaultFileLogLevel,
    }->makePinoConfig,
    {"target": "pino-pretty", "level": Config.userLogLevel}->makePinoConfig,
  ],
})
let logger = makeWithTransport(transport)

@genType
let setLogLevel = (level: Pino.logLevel) => {
  logger->setLevel(level)
}
setLogLevel(Config.baseLogLevel)

@genType
let trace = message => {
  logger.trace(. message->createPinoMessage)
}

@genType
let debug = message => {
  logger.debug(. message->createPinoMessage)
}

@genType
let info = message => {
  logger.info(. message->createPinoMessage)
}

@genType
let warn = message => {
  logger.warn(. message->createPinoMessage)
}

@genType
let error = message => {
  logger.error(. message->createPinoMessage)
}

@genType
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

/* // Testing usage:
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
