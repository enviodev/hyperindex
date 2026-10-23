// Guard: only allow execution from test runner
switch NodeJs.Process.process.env->Dict.get("ENVIO_TEST_LOGGING_FORMAT") {
| None =>
  JsError.throwWithMessage(
    "LogTesting.res should only be run via Logging.test.ts." ++ "Set ENVIO_TEST_LOGGING_FORMAT=1 to run directly.",
  )
| Some(_) => ()
}

open! Logger

// A logger's level is fixed when it is made, so each level gets its own, all
// writing where the run's environment says.
let loggerAt = level =>
  Logger.make({
    strategy: Env.Logger.strategy,
    logFile: Env.Logger.file,
    level,
    fileLevel: Env.Logger.fileLevel,
  })

let logger = loggerAt(Env.Logger.level->Option.getOr(#info))

// Per-item loggers are built by the ecosystem (the runtime gets it from
// `config.ecosystem`); this standalone fixture constructs one directly.
let ecosystem = Evm.make()

// Testing usage:
logger->trace("By default - This trace message should only be seen in the log file.")
logger->logAt(#debug, "By default - This debug message should only be seen in the log file.")
// Each logger writes from a thread of its own, so the next one waits for it.
logger->flush

exception SomethingWrong({myMessage: string})

let logAtEveryLevel = (~shown) => {
  let logger = loggerAt(shown)
  logger->info(`##Current log level: ${(shown :> string)}`)
  logger->trace("This is an trace message. (printed at trace only)")
  logger->logAt(#debug, "This is a debug message. (printed at debug and below)")
  logger->info("This is an info message.")
  logger->warn("This is a warning message.")
  logger->errorWithExn(
    "This is an error message.",
    SomethingWrong({myMessage: "example exception"}),
  )
  logger->logAt(#fatal, "This is a fatal message.", ~params={"extra": "another"})
  logger->flush
}

logAtEveryLevel(~shown=#info)
logAtEveryLevel(~shown=#debug)
logAtEveryLevel(~shown=#info)

// The per-item logger reads the contract and event names off the registration
// and the address off the payload; nothing else about the item is logged.
// A new item each time: an item keeps the logger first built for it.
let makeItem = () => Internal.Event({
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

let logUserLevels = (~shown, ~child) => {
  let logger = loggerAt(shown)
  // Built on the chain's logger, as the indexer builds it.
  let userLogger =
    makeItem()
    ->Ecosystem.loggerForItem(~ecosystem, ~logger=logger->withChainId(1337->ChainId.fromInt))
    ->asContextLog
  logger->info(`##Current log level: ${(shown :> string)}`)
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
  logger->flush
}

logUserLevels(~shown=#udebug, ~child="userLogs debug")
logUserLevels(~shown=#uinfo, ~child="userLogs info")
logUserLevels(~shown=#uwarn, ~child="userLogs warn")
logUserLevels(~shown=#uerror, ~child="userLogs error")
// A user's level passes where the level it's named after does.
logUserLevels(~shown=#warn, ~child="userLogs at warn")
logAtEveryLevel(~shown=#uerror)

logAtEveryLevel(~shown=#warn)
logAtEveryLevel(~shown=#error)

// Logging also works with params of all shapes and sizes
loggerAt(#error)->logAt(
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
