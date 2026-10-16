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
@send external nativeLog: (native, int, string, Null.t<string>, Null.t<string>) => unit = "log"
// Answers with the new minimum level.
@send external nativeSetLevel: (native, level) => int = "setLevel"
@send external nativeMinLevel: native => int = "minLevel"
@send external nativeCaptured: native => array<dict<JSON.t>> = "captured"
@send external nativeWriteCaptured: (native, string) => unit = "writeCaptured"

// Shared by a logger and every child of it, the way their sinks are, so a line
// no sink takes is dropped before its params are serialized.
type threshold = {mutable minLevel: int}

// A logger per query and per event is made whether or not it ever writes, so a
// child is only a record of its fields. They are serialized, joined to its
// parent's and kept the first time a line passes the level, and Rust merges
// them into each line it writes.
type rec t = {
  native: native,
  threshold: threshold,
  parent: option<t>,
  fields: unknown,
  mutable resolved: bool,
  mutable bindings: Null.t<string>,
}

let fromNative = native => {
  native,
  threshold: {minLevel: native->nativeMinLevel},
  parent: None,
  fields: %raw(`undefined`),
  resolved: true,
  bindings: Null.Null,
}

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
// carry), which `JSON.stringify` alone would drop as `{}`. The replacer that
// does it runs on every key, so params of plain values skip it. Params come
// from anywhere, so a value JSON can't hold says so rather than losing the line.
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
    for (var key in value) {
      var field = value[key];
      if (typeof field === "bigint" || (typeof field === "object" && field !== null)) {
        return JSON.stringify(value, replacer);
      }
    }
    return JSON.stringify(value);
  } catch (error) {
    return JSON.stringify({unserializable: String(error)});
  }
}`)

// Two JSON objects as one; a key in both is sent twice, and Rust keeps the
// later value.
let joinObjects = (parent: string, own: string) =>
  switch (parent, own) {
  | ("{}", _) => own
  | (_, "{}") => parent
  | _ =>
    parent->String.slice(~start=0, ~end=parent->String.length - 1) ++
    "," ++
    own->String.slice(~start=1)
  }

let rec bindingsOf = (logger: t) => {
  if !logger.resolved {
    let own = logger.fields->serialize
    let own = own->String.startsWith("{") ? own : `{"params":${own}}`
    logger.bindings = switch logger.parent->Option.map(bindingsOf) {
    | Some(Null.Value(parent)) => Null.Value(joinObjects(parent, own))
    | Some(Null.Null) | None => Null.Value(own)
    }
    logger.resolved = true
  }
  logger.bindings
}

let child = (logger: t, fields: 'a) => {
  native: logger.native,
  threshold: logger.threshold,
  parent: Some(logger),
  fields: fields->(Utils.magic: 'a => unknown),
  resolved: false,
  bindings: Null.Null,
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
      logger->bindingsOf,
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
