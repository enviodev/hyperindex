// What the resolver code logs through when its caller hands no logger in. The
// CLI always hands in its own; this exists for the server and pool being used
// on their own, which is how their tests drive them. Made on first use, so a
// process that never needs it never opens a second output.
let defaultLogger: ref<option<Logger.t>> = ref(None)

let getDefault = () =>
  switch defaultLogger.contents {
  | Some(logger) => logger
  | None =>
    let logger = Logger.make({
      strategy: Env.Logger.strategy,
      logFile: Env.Logger.file,
      level: Env.Logger.level->Option.getOr(#info),
      fileLevel: Env.Logger.fileLevel,
    })
    defaultLogger := Some(logger)
    logger
  }

let orDefault = (logger: option<Logger.t>) =>
  switch logger {
  | Some(logger) => logger
  | None => getDefault()
  }

// Whatever a JS caller passed as `logger`, or the default.
let fromJs = (logger: Nullable.t<Logger.t>) => logger->Nullable.toOption->orDefault

let info = (logger, message: string) => logger->Logger.info(message)
let warn = (logger, message: string) => logger->Logger.warn(message)
let error = (logger, message: string) => logger->Logger.error(message)
