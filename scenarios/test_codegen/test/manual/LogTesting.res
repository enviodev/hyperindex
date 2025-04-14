open Pino
open Logging

// For Logging.setLogger call
let _ = Env.logStrategy

// Testing usage:
trace("By default - This trace message should only be seen in the log file.")
debug("By default - This debug message should only be seen in the log file.")

exception SomethingWrong({myMessage: string})

info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
trace("This is an trace message.")
debug("This is a debug message.")
info("This is an info message.")
warn("This is a warning message.")
errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
fatal(("This is a fatal message.", "another"))

setLogLevel(#debug)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message.")
info("This is an info message.")
warn("This is a warning message.")
errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#info)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message.")
warn("This is a warning message.")
errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
fatal("This is a fatal message.")

@send external udebug: (Pino.t, 'a) => unit = "udebug"
@send external uinfo: (Pino.t, 'a) => unit = "uinfo"
@send external uwarn: (Pino.t, 'a) => unit = "uwarn"
@send external uerror: (Pino.t, 'a) => unit = "uerror"
setLogLevel(#udebug)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)

let userLogger = Logging.getUserLogger(createChild(~params={"child": "userLogs debug"}))
// Js.log(childLogger)
userLogger.debug("This is a user debug message.")
userLogger.info("This is a user info message.")
userLogger.warn("This is a user warn message.")
userLogger.error("This is a user error message.")
setLogLevel(#uinfo)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
let userLogger = Logging.getUserLogger(createChild(~params={"child": "userLogs info"}))
userLogger.debug("This is a user debug message.")
userLogger.info("This is a user info message.")
userLogger.warn(
  "This is a user warn message.",
  ~params={"type": "warn", "data": {"blockHash": "0x123"}},
)
userLogger.error("This is a user error message.")
userLogger.errorWithExn(
  "This is a user error with exception.",
  SomethingWrong({myMessage: "example exception"}),
)
setLogLevel(#uwarn)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
let userLogger = Logging.getUserLogger(createChild(~params={"child": "userLogs warn"}))
userLogger.debug("This is a user debug message.")
userLogger.info("This is a user info message.")
userLogger.warn("This is a user warn message.")
userLogger.error("This is a user error message.")
setLogLevel(#uerror)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
let userLogger = Logging.getUserLogger(createChild(~params={"child": "userLogs error"}))
userLogger.debug("This is a user debug message.")
userLogger.info("This is a user info message.")
userLogger.warn("This is a user warn message.")
userLogger.error("This is a user error message.")

setLogLevel(#warn)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message. (should not be printed)")
warn("This is a warning message.")
errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
fatal("This is a fatal message.")

setLogLevel(#error)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
trace("This is an trace message. (should not be printed)")
debug("This is a debug message. (should not be printed)")
info("This is an info message. (should not be printed)")
warn("This is a warning message. (should not be printed)")
errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
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
