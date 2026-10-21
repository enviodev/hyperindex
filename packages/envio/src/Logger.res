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
@send external makeInMemoryNative: Core.loggerCtor => native = "makeInMemory"
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
let makeInMemory = () => Core.getAddon().logger->makeInMemoryNative->wrapNative

// Errors serialize to their name, message and stack (and whatever else they
// carry), which `JSON.stringify` alone would drop as `{}`; an Error passed as the
// params lands under `err`. The replacer that does it runs on every key, so
// params of plain values skip it. Params come from anywhere, so a value that
// refers to itself says so, and one JSON can't hold says so rather than losing
// the line.
let paramsToJson: 'a => string = %raw(`function (value) {
  var ancestors = [];
  function replacer(_key, value) {
    if (typeof value === "bigint") return value.toString();
    if (typeof value !== "object" || value === null) return value;
    while (ancestors.length > 0 && ancestors[ancestors.length - 1] !== this) ancestors.pop();
    if (ancestors.includes(value)) return "[Circular]";
    ancestors.push(value);
    if (value instanceof Error) {
      var out = {type: value.name, message: value.message, stack: value.stack};
      for (var key of Object.keys(value)) out[key] = value[key];
      if (value.cause !== undefined) out.cause = value.cause;
      ancestors.push(out);
      return out;
    }
    return value;
  }
  try {
    if (value instanceof Error) value = {err: value};
    else if (typeof value === "bigint") return JSON.stringify(value, replacer);
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
// separately from the indexer's own. A plain-JS handler can pass a message
// that isn't a string, which must not throw out of the handler.
let asContextLog = (logger: t): Envio.logger => {
  let logAt = (level, message, ~params=?) =>
    logger->logAt(level, message->(Utils.magic: string => unknown)->String.make, ~params?)
  {
    info: (message: string, ~params=?) => logAt(#uinfo, message, ~params?),
    debug: (message: string, ~params=?) => logAt(#udebug, message, ~params?),
    warn: (message: string, ~params=?) => logAt(#uwarn, message, ~params?),
    error: (message: string, ~params=?) => logAt(#uerror, message, ~params?),
    errorWithExn: (message: string, exn) =>
      logAt(#uerror, message, ~params={"err": exn->Utils.prettifyExn}),
  }
}

type consoleClass
type writableClass
@module("node:console") external consoleClass: consoleClass = "Console"
@module("node:stream") external writableClass: writableClass = "Writable"

type formatWithOptions
@module("node:util") external formatWithOptions: formatWithOptions = "formatWithOptions"

// The common methods skip formatting when the level is off, and read a message
// and one plain object (or an Error) as `context.log`'s message and params;
// anything else is formatted into the message as Node's console would. The
// rest write through a `Console` of their level's own, so they format as
// Node's would, with group indentation kept per level.
let routeConsoleTo: (
  consoleClass,
  writableClass,
  formatWithOptions,
  level => bool,
  (level, string, Nullable.t<unknown>) => unit,
) => unit => unit = %raw(`(Console, Writable, formatWithOptions, isEnabled, write) => {
  const isParams = (value) =>
    value instanceof Error ||
    (typeof value === "object" && value !== null &&
      (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null));
  const direct = (level) => (...args) => {
    if (!isEnabled(level)) return;
    if (args.length === 2 && typeof args[0] === "string" && !args[0].includes("%") && isParams(args[1])) {
      write(level, args[0], args[1]);
    } else {
      write(level, formatWithOptions({colors: false}, ...args), undefined);
    }
  };
  const directByName = {log: "uinfo", info: "uinfo", debug: "udebug", warn: "uwarn", error: "uerror"};
  const viaConsoleByLevel = {
    uinfo: ["dir", "dirxml", "table", "count", "countReset", "group", "groupCollapsed", "groupEnd", "time", "timeEnd", "timeLog"],
    udebug: ["trace"],
    uwarn: ["assert"],
  };
  const original = [];
  const replace = (name, method) => {
    original.push([name, console[name]]);
    console[name] = method;
  };
  for (const name of Object.keys(directByName)) replace(name, direct(directByName[name]));
  for (const level of Object.keys(viaConsoleByLevel)) {
    const stream = new Writable({
      decodeStrings: false,
      write(chunk, _encoding, callback) {
        // Each call ends its output with a newline, which a line doesn't need.
        write(level, String(chunk).replace(/\n$/, ""), undefined);
        callback();
      },
    });
    const routed = new Console({stdout: stream, stderr: stream, colorMode: false});
    for (const name of viaConsoleByLevel[level]) replace(name, routed[name].bind(routed));
  }
  return () => original.forEach(([name, method]) => { console[name] = method; });
}`)

// A handler's `console` writes lines through `logger`, at the `u*` level its
// method names, instead of writing stdout behind the logger's back.
// `loggerFor` picks the logger in scope where the call is made, or `None` to
// drop the line. Returns the function that puts the original methods back.
let routeConsole = (logger: t, ~loggerFor: t => option<t>) =>
  routeConsoleTo(
    consoleClass,
    writableClass,
    formatWithOptions,
    level => levelNumber(level) >= logger.minLevel,
    (level, message, params) =>
      switch loggerFor(logger) {
      | Some(logger) => logger->logAt(level, message, ~params=?params->Nullable.toOption)
      | None => ()
      },
  )
