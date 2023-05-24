let currentLogLevel = ref(Config.defaultLogLevel)

let colors = (level: Config.logLevel) =>
  switch level {
  | #TRACE => "\x1b[35m"
  | #DEBUG => "\x1b[34m"
  | #INFO => "\x1b[32m"
  | #WARN => "\x1b[33m"
  | #ERROR => "\x1b[31m"
  | #FATAL => "\x1b[31m"
  }
let resetColor = "\x1b[0m"

let logLevelOrder = (level: Config.logLevel) =>
  switch level {
  | #TRACE => 0
  | #DEBUG => 1
  | #INFO => 2
  | #WARN => 3
  | #ERROR => 4
  | #FATAL => 5
  }

// TODO: sholud we provide a function for this? Should this just be an environment variable?
let setLogLevel = (level: Config.logLevel) => {
  currentLogLevel := level
}

let log = (level: Config.logLevel, message) => {
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

// TODO: set ethers and postgres log levels in a similar way
// TODO: use environment varibles to set log levels

/* // Testing usage:
setLogLevel(#TRACE)
trace("This is an trace message.")
debug("This is a debug message.")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#DEBUG)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message.")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#INFO)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message.")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#WARN)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message. (should not be printed)")
warn("This is a warning message.")
error("This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#ERROR)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message. (should not be printed)")
warn("This is a warning message. (should not be printed)")
error("This is an error message.")
fatal("This is a fatal message.")
*/
