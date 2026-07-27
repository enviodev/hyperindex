// The logger instances built from the process environment.
//
// Separate from `Logging` (which owns the logging API) because `Env` already
// sits below `Logging` in the dependency graph — it parses LOG_STRATEGY into a
// `Logging.logStrategyType`. Anything combining the two has to live above both.

// Instances are independent: setting the level on one can't affect another.
let make = (~userLogLevel=Env.userLogLevel->Option.getOr(#info)) =>
  Logging.makeLogger(
    ~logStrategy=Env.logStrategy,
    ~logFilePath=Env.logFilePath,
    ~defaultFileLogLevel=Env.defaultFileLogLevel,
    ~userLogLevel,
  )

// Sink for process-level logging that happens outside any indexer instance:
// bootstrap and pre-config errors, and `ErrorHandling`'s fallback logger.
let root = make()

%%private(let quietRef = ref(None))

// Shared by the in-process indexer instances nothing ever disposes (test
// indexers and mocks): pino exposes no way to release a logger's stream, so one
// logger per instance would leak a file handle per instance.
//
// Built on first use rather than at module load — `TestIndexer` is reachable
// from the package's public exports, so an eager instance would add a second
// logger (and, under the file-backed strategies, a second transport worker) to
// every production run.
let quiet = () =>
  switch quietRef.contents {
  | Some(logger) => logger
  | None =>
    let logger = switch Env.userLogLevel {
    // LOG_LEVEL was set explicitly — the developer asked to see these logs, and
    // the root logger already carries the level they requested.
    | Some(_) => root
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
