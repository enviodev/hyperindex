open Pino

let defaultPinoOptions = {
  level: Config.defaultLogLevel,
}
let logger = make(defaultPinoOptions)

// define log level order
let logLevelOrder = (level: logLevel) =>
  switch level {
  | #TRACE => "trace"
  | #DEBUG => "debug"
  | #INFO => "info"
  | #WARN => "warn"
  | #ERROR => "error"
  | #FATAL => "fatal"
  }

@genType
let setLogLevel = (level: Pino.logLevel) => {
  logger->setLevel(level)
}

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

// // TODO: set ethers and postgres log levels in a similar way
// // TODO: use environment varibles to set log levels

/* // Testing usage:
setLogLevel(#TRACE)
Js.log2("this is a summary of the available log levels", logger->levels)
Js.log(`Current log level: ${logger->getLevel->logLevelOrder}`)
trace("This is an trace message.")
debug("This is a debug message.")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal(("This is a fatal message.", "another"))

setLogLevel(#DEBUG)
Js.log(`Current log level: ${logger->getLevel->logLevelOrder}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message.")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#INFO)
Js.log(`Current log level: ${logger->getLevel->logLevelOrder}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#WARN)
Js.log(`Current log level: ${logger->getLevel->logLevelOrder}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message. (should not be printed)")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#ERROR)
Js.log(`Current log level: ${logger->getLevel->logLevelOrder}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message. (should not be printed)")
warn("This is a warning message. (should not be printed)")
error("This is an error message.")
fatal("This is a fatal message.")

// Logging also works with objects of all shapes and sizes
fatal({"this": "is", "a": "fatal", "message": "object", "with": {"nested": "objects", "and": {"arrays": ["of", "things"]}, "and": {"numbers": 0.5654}}})
 */
