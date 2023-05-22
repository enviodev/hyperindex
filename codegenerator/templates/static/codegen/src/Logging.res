module Logger = {
  type logLevel = [
    | #TRACE
    | #DEBUG
    | #INFO
    | #WARN
    | #ERROR
    | #FATAL
  ]

  let colors = (level: logLevel) =>
    switch level {
    | #TRACE => "\x1b[35m"
    | #DEBUG => "\x1b[34m"
    | #INFO => "\x1b[32m"
    | #WARN => "\x1b[33m"
    | #ERROR => "\x1b[31m"
    | #FATAL => "\x1b[31m"
    }
  let resetColor = "\x1b[0m"

  let logLevelOrder = (level: logLevel) =>
    switch level {
    | #TRACE => 0
    | #DEBUG => 1
    | #INFO => 2
    | #WARN => 3
    | #ERROR => 4
    | #FATAL => 5
    }

  let currentLogLevel = ref(#INFO)

  // TODO: sholud we provide a function for this? Should this just be an environment variable?
  let setLogLevel = (level: logLevel) => {
    currentLogLevel := level
  }

  let log = (level: logLevel, message) => {
    if logLevelOrder(level) >= logLevelOrder(currentLogLevel.contents) {
      Js.log2(`${colors(level)}[${(level :> string)}]${resetColor}`, message)
    }
  }

  let trace = message => {
    log(#TRACE, message)
  }

  let debug = message => {
    log(#DEBUG, message)
  }

  let info = message => {
    log(#INFO, message)
  }

  let warn = message => {
    log(#WARN, message)
  }

  let error = message => {
    log(#ERROR, message)
  }

  let fatal = message => {
    log(#FATAL, message)
  }
}

// TODO: set ethers and postgres log levels in a similar way
// TODO: use environment varibles to set log levels

/* // Testing usage:
Logger.setLogLevel(#TRACE)
Logger.trace("This is an trace message.")
Logger.debug("This is a debug message.")
Logger.info("This is an info message.")
Logger.warn("This is a warning message.")
Logger.error("This is an error message.")
Logger.fatal("This is a fatal message.")

Logger.setLogLevel(#DEBUG)
Logger.trace("This is an trace message. (should not be printed)")
Logger.debug("This is a debug message.")
Logger.info("This is an info message.")
Logger.warn("This is a warning message.")
Logger.error("This is an error message.")
Logger.fatal("This is a fatal message.")

Logger.setLogLevel(#INFO)
Logger.trace("This is an trace message. (should not be printed)")
Logger.debug("This is a debug message. (should not be printed)")
Logger.info("This is an info message.")
Logger.warn("This is a warning message.")
Logger.error("This is an error message.")
Logger.fatal("This is a fatal message.")

Logger.setLogLevel(#WARN)
Logger.trace("This is an trace message. (should not be printed)")
Logger.debug("This is a debug message. (should not be printed)")
Logger.info("This is an info message. (should not be printed)")
Logger.warn("This is a warning message.")
Logger.error("This is an error message.")
Logger.fatal("This is a fatal message.")

Logger.setLogLevel(#ERROR)
Logger.trace("This is an trace message. (should not be printed)")
Logger.debug("This is a debug message. (should not be printed)")
Logger.info("This is an info message. (should not be printed)")
Logger.warn("This is a warning message. (should not be printed)")
Logger.error("This is an error message.")
Logger.fatal("This is a fatal message.")
*/
