// Guard: only allow execution from test runner
switch NodeJs.Process.process.env->Dict.get("ENVIO_TEST_LOGGING_FORMAT") {
| None =>
  JsError.throwWithMessage(
    "LogTesting.res should only be run via Logging.test.ts. " ++ "Set ENVIO_TEST_LOGGING_FORMAT=1 to run directly.",
  )
| Some(_) => ()
}

open! Logging

let logger = Logging.make({
  strategy: Env.Logging.strategy,
  logFile: Env.Logging.file,
  level: Env.Logging.level->Option.getOr(#info),
  fileLevel: Env.Logging.fileLevel,
})

// Per-item loggers are built by the ecosystem (the runtime gets it from
// `config.ecosystem`); this standalone fixture constructs one directly.
let ecosystem = Evm.make()

// Testing usage:
logger->trace("By default - This trace message should only be seen in the log file.")
logger->logAt(#debug, "By default - This debug message should only be seen in the log file.")

exception SomethingWrong({myMessage: string})

let logAtEveryLevel = (~shown) => {
  logger->info(`##Current log level: ${shown}`)
  logger->trace("This is an trace message. (printed at trace only)")
  logger->logAt(#debug, "This is a debug message. (printed at debug and below)")
  logger->info("This is an info message.")
  logger->warn("This is a warning message.")
  logger->errorWithExn(
    "This is an error message.",
    SomethingWrong({myMessage: "example exception"}),
  )
  logger->logAt(#fatal, "This is a fatal message.", ~params={"extra": "another"})
}

logAtEveryLevel(~shown="info")

logger->setLevel(#debug)
logAtEveryLevel(~shown="debug")

logger->setLevel(#info)
logAtEveryLevel(~shown="info")

// The per-item logger reads the contract and event names off the registration
// and the address off the payload; nothing else about the item is logged.
let item = Internal.Event({
  chainId: 1337->ChainId.fromInt,
  blockNumber: 1,
  logIndex: 11,
  transactionIndex: 0,
  onEventRegistration: {
    "eventConfig": {"contractName": "Gravatar", "name": "NewGravatar"},
  }->(Utils.magic: {..} => Internal.onEventRegistration),
  payload: {
    "srcAddress": "0xabc0000000000000000000000000000000000000"->Address.Evm.fromStringOrThrow,
  }->(Utils.magic: {..} => Internal.eventPayload),
})

let userLogger = item->Ecosystem.loggerForItem(~ecosystem, ~logger)->asContextLog

let logUserLevels = (~shown, ~child) => {
  logger->info(`##Current log level: ${shown}`)
  userLogger.debug("This is a user debug message.", ~params={"child": child})
  userLogger.info("This is a user info message.", ~params={"child": child})
  userLogger.warn(
    "This is a user warn message.",
    ~params={"child": child, "type": "warn", "data": {"blockHash": "0x123"}},
  )
  userLogger.error("This is a user error message.", ~params={"child": child})
  userLogger.errorWithExn(
    "This is a user error with exception.",
    SomethingWrong({myMessage: "example exception"}),
  )
}

logger->setLevel(#udebug)
logUserLevels(~shown="udebug", ~child="userLogs debug")

logger->setLevel(#uinfo)
logUserLevels(~shown="uinfo", ~child="userLogs info")

logger->setLevel(#uwarn)
logUserLevels(~shown="uwarn", ~child="userLogs warn")

logger->setLevel(#uerror)
logUserLevels(~shown="uerror", ~child="userLogs error")

logger->setLevel(#warn)
logAtEveryLevel(~shown="warn")

logger->setLevel(#error)
logAtEveryLevel(~shown="error")

// Logging also works with params of all shapes and sizes
logger->logAt(
  #fatal,
  "A fatal message with nested params.",
  ~params={
    "this": "is",
    "a": "fatal",
    "message": "object",
    "with": {
      "nested": "objects",
      "and": {"arrays": ["of", "things"]},
      "additionally": {"numbers": 0.5654},
    },
  },
)
