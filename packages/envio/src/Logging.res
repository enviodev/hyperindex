type logStrategyType =
  | @as("ecs-file") EcsFile
  | @as("ecs-console") EcsConsole
  | @as("ecs-console-multistream") EcsConsoleMultistream
  | @as("file-only") FileOnly
  | @as("console-raw") ConsoleRaw
  | @as("console-pretty") ConsolePretty
  | @as("both-prettyconsole") Both

type level = [
  | #trace
  | #debug
  | #info
  | #udebug
  | #uinfo
  | #uwarn
  | #uerror
  | #warn
  | #error
  | #fatal
  | #silent
]

// Mirrors the Rust `Level` values, so the level check happens on this side.
let levelValue = (level: level) =>
  switch level {
  | #trace => 10
  | #debug => 20
  | #info => 30
  | #udebug => 32
  | #uinfo => 34
  | #uwarn => 36
  | #uerror => 38
  | #warn => 40
  | #error => 50
  | #fatal => 60
  | #silent => 2147483647
  }

type native
type options = {
  strategy: string,
  logFile: string,
  level: level,
  fileLevel: level,
}
@send external makeNative: (Core.loggerCtor, options) => native = "make"
@send external nativeChild: (native, string) => native = "child"
@send external nativeLog: (native, int, string, Null.t<string>) => unit = "log"
// Answers with the new minimum level.
@send external nativeSetLevel: (native, level) => int = "setLevel"
@send external nativeMinLevel: native => int = "minLevel"
@send external nativeCaptured: native => array<dict<JSON.t>> = "captured"
@send external nativeWriteCaptured: (native, string) => unit = "writeCaptured"

// Shared by a logger and every child of it, the way their sinks are, so a line
// no sink takes is dropped before its params are serialized.
type threshold = {mutable minLevel: int}

type t = {native: native, threshold: threshold}

let fromNative = native => {native, threshold: {minLevel: native->nativeMinLevel}}

let make = (~strategy: logStrategyType, ~logFile, ~level, ~fileLevel) =>
  Core.getAddon().logger
  ->makeNative({strategy: (strategy :> string), logFile, level, fileLevel})
  ->fromNative

// Keeps every line in memory for a test to read back as JSON, instead of
// writing it anywhere.
let capture = () =>
  Core.getAddon().logger
  ->makeNative({strategy: "capture", logFile: "", level: #trace, fileLevel: #silent})
  ->fromNative

// Errors serialize to their name, message and stack (and whatever else they
// carry), which `JSON.stringify` alone would drop as `{}`. Params come from
// anywhere, so a value JSON can't hold says so rather than losing the line.
let serialize: 'a => string = %raw(`function (value) {
  function replacer(_key, value) {
    if (typeof value === "bigint") return value.toString();
    if (value instanceof Error) {
      var out = {type: value.name, message: value.message, stack: value.stack};
      for (var key of Object.keys(value)) out[key] = value[key];
      if (value.cause !== undefined) out.cause = value.cause;
      return out;
    }
    return value;
  }
  try {
    return JSON.stringify(value, replacer);
  } catch (error) {
    return JSON.stringify({unserializable: String(error)});
  }
}`)

let child = (logger: t, params: 'a) => {
  native: logger.native->nativeChild(params->serialize),
  threshold: logger.threshold,
}

// Every line about one chain names it, so the run's lines can be told apart.
let forChain = (logger: t, chainId: ChainId.t) => logger->child({"chainId": chainId})

let setLevel = (logger: t, level: level) =>
  logger.threshold.minLevel = logger.native->nativeSetLevel(level)

let log = (logger: t, level: level, message: string, ~params: option<'a>=?) =>
  if levelValue(level) >= logger.threshold.minLevel {
    logger.native->nativeLog(
      levelValue(level),
      message,
      switch params {
      | Some(params) => Null.Value(params->serialize)
      | None => Null.Null
      },
    )
  }

let trace = (logger, message, ~params=?) => logger->log(#trace, message, ~params?)
let info = (logger, message, ~params=?) => logger->log(#info, message, ~params?)
let warn = (logger, message, ~params=?) => logger->log(#warn, message, ~params?)
let error = (logger, message, ~params=?) => logger->log(#error, message, ~params?)

let errorWithExn = (logger, message, exn) =>
  logger->log(#error, message, ~params={"err": exn->Utils.prettifyExn})

// Every line a `capture` logger has taken, oldest first: `level` and `msg`,
// then the fields the logger and the call added.
let captured = (logger: t) => logger.native->nativeCaptured

let writeCaptured = (logger: t, ~path) => logger.native->nativeWriteCaptured(path)

let noopLogger: Envio.logger = {
  info: (_message: string, ~params as _=?) => (),
  debug: (_message: string, ~params as _=?) => (),
  warn: (_message: string, ~params as _=?) => (),
  error: (_message: string, ~params as _=?) => (),
  errorWithExn: (_message: string, _exn) => (),
}

// The user-facing `context.log`, on the `u*` levels a user's log level filters
// separately from the indexer's own.
let userLogger = (logger: t): Envio.logger => {
  info: (message: string, ~params=?) => logger->log(#uinfo, message, ~params?),
  debug: (message: string, ~params=?) => logger->log(#udebug, message, ~params?),
  warn: (message: string, ~params=?) => logger->log(#uwarn, message, ~params?),
  error: (message: string, ~params=?) => logger->log(#uerror, message, ~params?),
  errorWithExn: (message: string, exn) =>
    logger->log(#uerror, message, ~params={"err": exn->Utils.prettifyExn}),
}
