// The logger instances built from the process environment.
//
// Separate from `Logging` (which owns the logging API) because `Env` already
// sits below `Logging` in the dependency graph — it parses LOG_STRATEGY into a
// `Logging.logStrategyType`. Anything combining the two has to live above both.
//
// Nothing here is built at import time. The entry point (`Bin`) constructs the
// one process logger and threads it into the commands it runs, so no code can
// reach a console-level logger ambiently — which is what let tests silently
// start logging to real output. In-process indexers use `quiet`.

// Instances are independent: setting the level on one can't affect another.
let make = (~userLogLevel=Env.userLogLevel->Option.getOr(#info)) =>
  Logging.makeLogger(
    ~logStrategy=Env.logStrategy,
    ~logFilePath=Env.logFilePath,
    ~defaultFileLogLevel=Env.defaultFileLogLevel,
    ~userLogLevel,
  )

%%private(let quietRef = ref(None))

// Shared by the in-process indexer instances nothing ever disposes (test
// indexers and mocks): pino exposes no way to release a logger's stream, so one
// logger per instance would leak a file handle per instance.
let quiet = () =>
  switch quietRef.contents {
  | Some(logger) => logger
  | None =>
    let logger = switch Env.userLogLevel {
    // LOG_LEVEL was set explicitly — the developer asked to see these logs.
    | Some(_) => make()
    | None =>
      let logger = make(~userLogLevel=#silent)
      // The file-backed strategies build at their own file level and ignore
      // `userLogLevel`, so silence has to be set on the instance.
      logger->Logging.setLogLevel(#silent)
      logger
    }
    quietRef := Some(logger)
    logger
  }
