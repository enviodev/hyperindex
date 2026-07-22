// Guard: only allow execution from test runner
switch NodeJs.Process.process.env->Dict.get("ENVIO_TEST_LOGGING_FORMAT") {
| None =>
  JsError.throwWithMessage(
    "LogTesting.res should only be run via Logging.test.ts. " ++ "Set ENVIO_TEST_LOGGING_FORMAT=1 to run directly.",
  )
| Some(_) => ()
}

open Pino
open Logging

// The process base logger, built from LOG_STRATEGY/LOG_LEVEL env vars by Env.
let logger = Env.logger

// Per-item loggers are built by the ecosystem (the runtime gets it from
// `config.ecosystem`); this standalone fixture constructs one directly.
let ecosystem = Evm.make(~logger)

// Testing usage:
logger->childTrace("By default - This trace message should only be seen in the log file.")
logger->childDebug("By default - This debug message should only be seen in the log file.")

exception SomethingWrong({myMessage: string})

logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)
logger->childTrace("This is an trace message.")
logger->childDebug("This is a debug message.")
logger->childInfo("This is an info message.")
logger->childWarn("This is a warning message.")
logger->childErrorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->childFatal(("This is a fatal message.", "another"))

logger->setLogLevel(#debug)
logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)
logger->childTrace("This is an trace message. (should not be printed)")
logger->childDebug("This is a debug message.")
logger->childInfo("This is an info message.")
logger->childWarn("This is a warning message.")
logger->childErrorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->childFatal("This is a fatal message.")

logger->setLogLevel(#info)
logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)
logger->childTrace("This is an trace message. (should not be printed)")
logger->childDebug("This is a debug message. (should not be printed)")
logger->childInfo("This is an info message.")
logger->childWarn("This is a warning message.")
logger->childErrorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->childFatal("This is a fatal message.")

@send external udebug: (Pino.t, 'a) => unit = "udebug"
@send external uinfo: (Pino.t, 'a) => unit = "uinfo"
@send external uwarn: (Pino.t, 'a) => unit = "uwarn"
@send external uerror: (Pino.t, 'a) => unit = "uerror"
logger->setLogLevel(#udebug)
logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)

let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

let userLogger = Ecosystem.getItemUserLogger(item, ~ecosystem)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs debug"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs debug"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs debug"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs debug"})

logger->setLogLevel(#uinfo)
logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)

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
logger->setLogLevel(#uwarn)
logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs warn"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs warn"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs warn"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs warn"})

logger->setLogLevel(#uerror)
logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs error"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs error"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs error"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs error"})

logger->setLogLevel(#warn)
logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)
logger->childTrace("This is an trace message. (should not be printed)")
logger->childDebug("This is a debug message. (should not be printed)")
logger->childInfo("This is an info message. (should not be printed)")
logger->childWarn("This is a warning message.")
logger->childErrorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->childFatal("This is a fatal message.")

logger->setLogLevel(#error)
logger->childInfo(`##Current log level: ${(logger->getLevel :> string)}`)
logger->childTrace("This is an trace message. (should not be printed)")
logger->childDebug("This is a debug message. (should not be printed)")
logger->childInfo("This is an info message. (should not be printed)")
logger->childWarn("This is a warning message. (should not be printed)")
logger->childErrorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->childFatal("This is a fatal message.")

// Logging also works with objects of all shapes and sizes
logger->childFatal({
  "this": "is",
  "a": "fatal",
  "message": "object",
  "with": {
    "nested": "objects",
    "and": {"arrays": ["of", "things"]},
    "additionally": {"numbers": 0.5654},
  },
})
