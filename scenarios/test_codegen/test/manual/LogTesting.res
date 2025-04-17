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

let eventItem = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

let userLogger = Logging.getUserLogger(eventItem)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs debug"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs debug"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs debug"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs debug"})

setLogLevel(#uinfo)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)

userLogger.debug("This is a user debug message.", ~params={"child": "userLogs info"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs info"})
userLogger.warn(
  "This is a user warn message.",
  ~params={"child": "userLogs info", "type": "warn", "data": {"blockHash": "0x123"}},
)
userLogger.error("This is a user error message.", ~params={"child": "userLogs info"})
userLogger.errorWithExn(
  "This is a user error with exception.",
  SomethingWrong({myMessage: "example exception"}),
)
setLogLevel(#uwarn)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs warn"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs warn"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs warn"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs warn"})

setLogLevel(#uerror)
info(`##Current log level: ${(getLogger()->getLevel :> string)}`)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs error"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs error"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs error"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs error"})

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
