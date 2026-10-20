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

// The level check happens here, before a line crosses into Rust, so these are
// Rust's numbers. `Logging.test.ts` runs a process at every level and compares
// what it printed, which is where the two would be seen to disagree.
let levelNumber = (level: level) =>
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

// Where the lines go: a `LOG_STRATEGY` value, which Rust validates, with the
// terminal's level and the log file's.
type config = {
  strategy: string,
  logFile: string,
  level: level,
  fileLevel: level,
}

type native
@send external makeNative: (Core.loggerCtor, config) => native = "make"
@send
external nativeLog: (
  native,
  ~level: int,
  ~message: string,
  ~boundFieldsJson: Null.t<string>,
  ~paramsJson: Null.t<string>,
) => unit = "log"
@send external nativeMinLevel: native => int = "minLevel"
@send external nativeInMemoryLines: native => array<dict<JSON.t>> = "inMemoryLines"
@send
external nativeWriteInMemoryLinesToFile: (native, string) => unit = "writeInMemoryLinesToFile"

// A logger per query and per event is made whether or not it ever writes, so a
// derived logger is only a record of its fields. They are serialized, joined to
// its parent's and kept the first time a line passes the level, and Rust merges
// them into each line it writes.
type rec t = {
  native: native,
  // The lowest level any sink takes, fixed when the logger is made, so a line no
  // sink takes is dropped before its params are serialized.
  minLevel: int,
  parent: option<t>,
  fields: unknown,
  mutable isBoundFieldsJsonReady: bool,
  mutable boundFieldsJson: Null.t<string>,
}

let wrapNative = native => {
  native,
  minLevel: native->nativeMinLevel,
  parent: None,
  fields: %raw(`undefined`),
  isBoundFieldsJsonReady: true,
  boundFieldsJson: Null.Null,
}

let make = (config: config) => Core.getAddon().logger->makeNative(config)->wrapNative

// Keeps every line in memory, where a test reads it back as JSON.
let makeInMemory = () =>
  Core.getAddon().logger
  ->makeNative({strategy: "in-memory", logFile: "", level: #trace, fileLevel: #silent})
  ->wrapNative

// Errors serialize to their name, message and stack (and whatever else they
// carry), which `JSON.stringify` alone would drop as `{}`. The replacer that
// does it runs on every key, so params of plain values skip it. Params come
// from anywhere, so a value JSON can't hold says so rather than losing the line.
let paramsToJson: 'a => string = %raw(`function (value) {
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
let concatJsonObjects = (parent: string, own: string) =>
  switch (parent, own) {
  | ("{}", _) => own
  | (_, "{}") => parent
  | _ =>
    parent->String.slice(~start=0, ~end=parent->String.length - 1) ++
    "," ++
    own->String.slice(~start=1)
  }

let rec getBoundFieldsJson = (logger: t) => {
  if !logger.isBoundFieldsJsonReady {
    let own = logger.fields->paramsToJson
    let own = own->String.startsWith("{") ? own : `{"params":${own}}`
    logger.boundFieldsJson = switch logger.parent->Option.map(getBoundFieldsJson) {
    | Some(Null.Value(parent)) => Null.Value(concatJsonObjects(parent, own))
    | Some(Null.Null) | None => Null.Value(own)
    }
    logger.isBoundFieldsJsonReady = true
  }
  logger.boundFieldsJson
}

// A logger adding `fields` to every line it writes.
let withFields = (logger: t, fields: 'a) => {
  native: logger.native,
  minLevel: logger.minLevel,
  parent: Some(logger),
  fields: fields->(Utils.magic: 'a => unknown),
  isBoundFieldsJsonReady: false,
  boundFieldsJson: Null.Null,
}

// Every line about one chain names it, so the run's lines can be told apart.
let withChainId = (logger: t, chainId: ChainId.t) => logger->withFields({"chainId": chainId})

let logAt = (logger: t, level: level, message: string, ~params: option<'a>=?) =>
  if levelNumber(level) >= logger.minLevel {
    logger.native->nativeLog(
      ~level=levelNumber(level),
      ~message,
      ~boundFieldsJson=logger->getBoundFieldsJson,
      ~paramsJson=switch params {
      | Some(params) => Null.Value(params->paramsToJson)
      | None => Null.Null
      },
    )
  }

let trace = (logger, message, ~params=?) => logger->logAt(#trace, message, ~params?)
let info = (logger, message, ~params=?) => logger->logAt(#info, message, ~params?)
let warn = (logger, message, ~params=?) => logger->logAt(#warn, message, ~params?)
let error = (logger, message, ~params=?) => logger->logAt(#error, message, ~params?)

let errorWithExn = (logger, message, exn) =>
  logger->logAt(#error, message, ~params={"err": exn->Utils.prettifyExn})

// Every line an in-memory logger has taken, oldest first: `level` and `msg`,
// then the fields the logger and the call added.
let inMemoryLines = (logger: t) => logger.native->nativeInMemoryLines

let writeInMemoryLinesToFile = (logger: t, ~path) =>
  logger.native->nativeWriteInMemoryLinesToFile(path)

// `context.log` while a handler is only being preloaded, which must not log.
let silentContextLog: Envio.logger = {
  info: (_message: string, ~params as _=?) => (),
  debug: (_message: string, ~params as _=?) => (),
  warn: (_message: string, ~params as _=?) => (),
  error: (_message: string, ~params as _=?) => (),
  errorWithExn: (_message: string, _exn) => (),
}

// The handler's `context.log`, on the `u*` levels a user's log level filters
// separately from the indexer's own.
let asContextLog = (logger: t): Envio.logger => {
  info: (message: string, ~params=?) => logger->logAt(#uinfo, message, ~params?),
  debug: (message: string, ~params=?) => logger->logAt(#udebug, message, ~params?),
  warn: (message: string, ~params=?) => logger->logAt(#uwarn, message, ~params?),
  error: (message: string, ~params=?) => logger->logAt(#uerror, message, ~params?),
  errorWithExn: (message: string, exn) =>
    logger->logAt(#uerror, message, ~params={"err": exn->Utils.prettifyExn}),
}
