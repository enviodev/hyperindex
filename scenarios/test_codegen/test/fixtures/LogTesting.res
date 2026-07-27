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

// This fixture asserts on real log output, so it uses the process logger
// rather than the quiet one the rest of the tests share.
let logger = Logger.root

let ecosystem = Evm.make()

// Testing usage:
logger->trace("By default - This trace message should only be seen in the log file.")
logger->debug("By default - This debug message should only be seen in the log file.")

exception SomethingWrong({myMessage: string})

logger->info(`##Current log level: ${(logger->getLevel :> string)}`)
logger->trace("This is an trace message.")
logger->debug("This is a debug message.")
logger->info("This is an info message.")
logger->warn("This is a warning message.")
logger->errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->fatal(("This is a fatal message.", "another"))

logger->setLogLevel(#debug)
logger->info(`##Current log level: ${(logger->getLevel :> string)}`)
logger->trace("This is an trace message. (should not be printed)")
logger->debug("This is a debug message.")
logger->info("This is an info message.")
logger->warn("This is a warning message.")
logger->errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->fatal("This is a fatal message.")

logger->setLogLevel(#info)
logger->info(`##Current log level: ${(logger->getLevel :> string)}`)
logger->trace("This is an trace message. (should not be printed)")
logger->debug("This is a debug message. (should not be printed)")
logger->info("This is an info message.")
logger->warn("This is a warning message.")
logger->errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->fatal("This is a fatal message.")

@send external udebug: (Pino.t, 'a) => unit = "udebug"
@send external uinfo: (Pino.t, 'a) => unit = "uinfo"
@send external uwarn: (Pino.t, 'a) => unit = "uwarn"
@send external uerror: (Pino.t, 'a) => unit = "uerror"
logger->setLogLevel(#udebug)
logger->info(`##Current log level: ${(logger->getLevel :> string)}`)

let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem

let userLogger = Ecosystem.getItemUserLogger(item, ~ecosystem, ~logger)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs debug"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs debug"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs debug"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs debug"})

logger->setLogLevel(#uinfo)
logger->info(`##Current log level: ${(logger->getLevel :> string)}`)

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
logger->info(`##Current log level: ${(logger->getLevel :> string)}`)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs warn"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs warn"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs warn"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs warn"})

logger->setLogLevel(#uerror)
logger->info(`##Current log level: ${(logger->getLevel :> string)}`)
userLogger.debug("This is a user debug message.", ~params={"child": "userLogs error"})
userLogger.info("This is a user info message.", ~params={"child": "userLogs error"})
userLogger.warn("This is a user warn message.", ~params={"child": "userLogs error"})
userLogger.error("This is a user error message.", ~params={"child": "userLogs error"})

logger->setLogLevel(#warn)
logger->info(`##Current log level: ${(logger->getLevel :> string)}`)
logger->trace("This is an trace message. (should not be printed)")
logger->debug("This is a debug message. (should not be printed)")
logger->info("This is an info message. (should not be printed)")
logger->warn("This is a warning message.")
logger->errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->fatal("This is a fatal message.")

logger->setLogLevel(#error)
logger->info(`##Current log level: ${(logger->getLevel :> string)}`)
logger->trace("This is an trace message. (should not be printed)")
logger->debug("This is a debug message. (should not be printed)")
logger->info("This is an info message. (should not be printed)")
logger->warn("This is a warning message. (should not be printed)")
logger->errorWithExn(SomethingWrong({myMessage: "example exception"}), "This is an error message.")
logger->fatal("This is a fatal message.")

// Logging also works with objects of all shapes and sizes
logger->fatal({
  "this": "is",
  "a": "fatal",
  "message": "object",
  "with": {
    "nested": "objects",
    "and": {"arrays": ["of", "things"]},
    "additionally": {"numbers": 0.5654},
  },
})
