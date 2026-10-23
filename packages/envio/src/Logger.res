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
@send external nativeMinLevel: native => int = "minLevel"
@send external nativeFlush: native => unit = "flush"
@send external nativeInMemoryLines: native => array<dict<JSON.t>> = "inMemoryLines"
@send
external nativeWriteInMemoryLinesToFile: (native, string) => unit = "writeInMemoryLinesToFile"
@send external nativeWrite: (native, NodeJs.Buffer.t, int) => unit = "write"

@val @scope("Buffer") external allocUnsafe: int => NodeJs.Buffer.t = "allocUnsafe"
@get external bufferArrayBuffer: NodeJs.Buffer.t => ArrayBuffer.t = "buffer"
@get external bufferByteOffset: NodeJs.Buffer.t => int = "byteOffset"
@get external bufferLength: NodeJs.Buffer.t => int = "length"
@send external subarray: (NodeJs.Buffer.t, int, int) => NodeJs.Buffer.t = "subarray"

// Lines wait here and cross into Rust many at a time, already UTF-8: a call or
// a string copy per line would cost more than the line. Every logger derived
// from one shares its output. Laid out as Rust's `Batch` reads it.
type output = {
  native: native,
  mutable bytes: NodeJs.Buffer.t,
  mutable view: DataView.t,
  mutable offset: int,
  mutable lines: int,
  mutable isFlushScheduled: bool,
  mutable lastFlushTime: float,
}

let bufferSize = 1048576

let viewOf = bytes =>
  DataView.fromBuffer(
    bytes->bufferArrayBuffer,
    ~byteOffset=bytes->bufferByteOffset,
    ~length=bytes->bufferLength,
  )

let setBytes = (output, size) => {
  let bytes = allocUnsafe(size)
  output.bytes = bytes
  output.view = viewOf(bytes)
}

let makeOutput = native => {
  let bytes = allocUnsafe(bufferSize)
  {
    native,
    bytes,
    view: viewOf(bytes),
    offset: 0,
    lines: 0,
    isFlushScheduled: false,
    lastFlushTime: 0.,
  }
}

let handOver = output =>
  if output.lines > 0 {
    output.native->nativeWrite(output.bytes->subarray(0, output.offset), output.lines)
    output.offset = 0
    output.lines = 0

    // A line larger than the buffer grew it; the next batch needn't keep it.
    if output.bytes->bufferLength > bufferSize {
      output->setBytes(bufferSize)
    }
  }

// Writes one line into `output`, flushing first when it might not fit. A UTF-16
// code unit is at most three UTF-8 bytes, which bounds a line before writing it.
let appendLine: (
  output,
  ~handOver: output => unit,
  ~setBytes: (output, int) => unit,
  ~level: int,
  ~time: float,
  ~message: string,
  ~boundFieldsJson: array<string>,
  ~paramsJson: Null.t<string>,
) => unit = %raw(`function (output, handOver, setBytes, level, time, message, bound, params) {
  var need = 18 + 3 * (message.length + (params === null ? 0 : params.length));
  for (var i = 0; i < bound.length; i++) need += 4 + 3 * bound[i].length;
  if (output.offset + need > output.bytes.length) {
    handOver(output);
    if (need > output.bytes.length) setBytes(output, need);
  }
  var bytes = output.bytes, view = output.view, offset = output.offset;
  bytes[offset] = level;
  view.setFloat64(offset + 1, time, true);
  offset += 9;
  var written = bytes.write(message, offset + 4, "utf8");
  view.setUint32(offset, written, true);
  offset += 4 + written;
  bytes[offset++] = bound.length;
  for (var i = 0; i < bound.length; i++) {
    written = bytes.write(bound[i], offset + 4, "utf8");
    view.setUint32(offset, written, true);
    offset += 4 + written;
  }
  if (params === null) { view.setUint32(offset, 0xFFFFFFFF, true); offset += 4; }
  else { written = bytes.write(params, offset + 4, "utf8"); view.setUint32(offset, written, true); offset += 4 + written; }
  output.offset = offset;
  output.lines++;
}`)

// Enough lines that the call costs little per line.
let maxPendingLines = 1024
// While lines keep coming, none waits longer than this behind microtasks that
// never yield to the event loop, where the scheduled flush runs.
let maxPendingMs = 20.

type t = {
  output: output,
  // The lowest level any sink takes, fixed when the logger is made, so a line no
  // sink takes is dropped before its params are serialized.
  minLevel: int,
  // The fields of the logger and its parents as JSON objects, parents first,
  // each kept as its own string so a logger made per line doesn't copy its
  // parents' into one. Rust merges them into each line it writes.
  boundFieldsJson: array<string>,
}

let wrapNative = native => {
  output: makeOutput(native),
  minLevel: native->nativeMinLevel,
  boundFieldsJson: [],
}

// Returns once every line logged so far is written.
let flush = (logger: t) => {
  logger.output->handOver
  logger.output.native->nativeFlush
}

let loggers: array<t> = []

// Lines are written off the JS thread, so the ones still waiting when the
// process exits, or is stopped by a signal, are written before it goes. A
// signal nothing else handles is raised again once its listener is gone, so its
// default action still ends the process; one that something else handles is
// left to it, and the exit that follows flushes again.
let flushOnExit: (unit => unit) => unit = %raw(`function (flushAll) {
  process.on("exit", flushAll);
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.once(signal, () => {
      flushAll();
      if (process.listenerCount(signal) === 0) process.kill(process.pid, signal);
    });
  }
}`)

let make = (config: config) => {
  let logger = Core.getAddon().logger->makeNative(config)->wrapNative
  if loggers->Array.length === 0 {
    flushOnExit(() => loggers->Array.forEach(flush))
  }
  loggers->Array.push(logger)
  logger
}

// Keeps every line in memory, where a test reads it back as JSON.
let makeInMemory = () => Core.getAddon().logger->makeInMemoryNative->wrapNative

// Errors serialize to their name, message and stack (and whatever else they
// carry), which `JSON.stringify` alone would drop as `{}`; an Error passed as the
// params lands under `err`. The replacer that does it runs on every key, so
// params of plain values skip it. Params come from anywhere, so a value that
// refers to itself says so, and one JSON can't hold says so rather than losing
// the line. Params repeat the same few keys, so their JSON is kept.
let unknownToJson: unknown => string = %raw(`(() => {
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
      // An AggregateError's own errors aren't enumerable.
      if (Array.isArray(value.errors)) out.errors = value.errors;
      ancestors.push(out);
      return out;
    }
    return value;
  }
  // A key or string without quotes, backslashes, control characters or
  // surrogates is its own JSON between quotes.
  var plain = /^[^"\\\u0000-\u001f\ud800-\udfff]*$/;
  function quote(text) {
    return plain.test(text) ? '"' + text + '"' : JSON.stringify(text);
  }
  var quotedKeys = new Map();
  function quoteKey(key) {
    var quoted = quotedKeys.get(key);
    if (quoted === undefined) {
      quoted = quote(key);
      if (quotedKeys.size < 4096) quotedKeys.set(key, quoted);
    }
    return quoted;
  }
  // A toJSON or getter the replacer runs may log, so a nested call keeps its
  // own ancestors.
  function stringify(value) {
    var outer = ancestors;
    ancestors = [];
    try {
      return JSON.stringify(value, replacer);
    } finally {
      ancestors = outer;
    }
  }
  return function (value) {
  try {
    if (value instanceof Error) value = {err: value};
    else if (
      typeof value !== "object" || value === null || typeof value.toJSON === "function" ||
      (Object.getPrototypeOf(value) !== Object.prototype && Object.getPrototypeOf(value) !== null)
    ) {
      // What JSON can't hold at all, such as a function, is no params.
      var json = stringify(value);
      return json === undefined ? "{}" : json;
    }
    // Params are almost always one flat plain object, written here without the
    // replacer, which costs more than the line; anything nested takes it.
    var json = "{";
    for (var key in value) {
      var field = value[key];
      var fieldJson;
      switch (typeof field) {
        case "string": fieldJson = quote(field); break;
        case "number": fieldJson = isFinite(field) ? "" + field : "null"; break;
        case "bigint": fieldJson = '"' + field + '"'; break;
        case "boolean": fieldJson = field ? "true" : "false"; break;
        case "undefined": case "function": case "symbol": continue;
        default:
          if (field !== null) return stringify(value);
          fieldJson = "null";
      }
      json += (json.length === 1 ? "" : ",") + quoteKey(key) + ":" + fieldJson;
    }
    return json + "}";
  } catch (error) {
    return JSON.stringify({unserializable: String(error)});
  }
  };
})()`)
let paramsToJson = (value: 'a) => value->(Utils.magic: 'a => unknown)->unknownToJson

// A logger adding the fields of `json`, a JSON object: for a logger made per
// line, whose fields' JSON is cheaper built from parts than serialized.
let withFieldsJson = (logger: t, json: string) => {
  ...logger,
  boundFieldsJson: json === "{}"
    ? logger.boundFieldsJson
    : logger.boundFieldsJson->Array.concat([json]),
}

// A logger adding `fields` to every line it writes.
let withFields = (logger: t, fields: 'a) => logger->withFieldsJson(fields->paramsToJson)

// Every line about one chain names it, so the run's lines can be told apart.
let withChainId = (logger: t, chainId: ChainId.t) => logger->withFields({"chainId": chainId})

let logAt = (logger: t, level: level, message: string, ~params: option<'a>=?) =>
  if levelNumber(level) >= logger.minLevel {
    let output = logger.output
    let time = Date.now()
    output->appendLine(
      ~handOver,
      ~setBytes,
      ~level=levelNumber(level),
      ~time,
      ~message,
      ~boundFieldsJson=logger.boundFieldsJson,
      ~paramsJson=switch params {
      | Some(params) => Null.Value(params->paramsToJson)
      | None => Null.Null
      },
    )
    if output.lines >= maxPendingLines || time -. output.lastFlushTime >= maxPendingMs {
      output.lastFlushTime = time
      output->handOver
    } else if !output.isFlushScheduled {
      output.isFlushScheduled = true
      NodeJs.setImmediate(() => {
        output.isFlushScheduled = false
        output.lastFlushTime = Date.now()
        output->handOver
      })
    }
  }

let trace = (logger, message, ~params=?) => logger->logAt(#trace, message, ~params?)
let info = (logger, message, ~params=?) => logger->logAt(#info, message, ~params?)
let warn = (logger, message, ~params=?) => logger->logAt(#warn, message, ~params?)
let error = (logger, message, ~params=?) => logger->logAt(#error, message, ~params?)

let errorWithExn = (logger, message, exn) =>
  logger->logAt(#error, message, ~params={"err": exn->Utils.prettifyExn})

// Every line an in-memory logger has taken, oldest first: `level` and `msg`,
// then the fields the logger and the call added.
let inMemoryLines = (logger: t) => {
  logger.output->handOver
  logger.output.native->nativeInMemoryLines
}

let writeInMemoryLinesToFile = (logger: t, ~path) => {
  logger.output->handOver
  logger.output.native->nativeWriteInMemoryLinesToFile(path)
}

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

// The common methods skip formatting when no logger takes the line, and read a
// message and one plain object (or an Error) as `context.log`'s message and
// params; anything else is formatted into the message as Node's console would.
// The rest write through a `Console` of their level's own, so they format as
// Node's would; `console.group` indents only those.
let routeConsoleTo: (
  consoleClass,
  writableClass,
  formatWithOptions,
  level => Nullable.t<t>,
  (t, level, string, Nullable.t<unknown>) => unit,
) => unit => unit = %raw(`(Console, Writable, formatWithOptions, loggerFor, write) => {
  const isParams = (value) =>
    value instanceof Error ||
    (typeof value === "object" && value !== null &&
      (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null));
  const direct = (level) => (...args) => {
    const logger = loggerFor(level);
    if (logger == null) return;
    if (args.length === 2 && typeof args[0] === "string" && !args[0].includes("%") && isParams(args[1])) {
      write(logger, level, args[0], args[1]);
    } else {
      write(logger, level, formatWithOptions({colors: false}, ...args), undefined);
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
        const logger = loggerFor(level);
        // Each call ends its output with a newline, which a line doesn't need.
        if (logger != null) write(logger, level, String(chunk).replace(/\n$/, ""), undefined);
        callback();
      },
    });
    const routed = new Console({stdout: stream, stderr: stream, colorMode: false});
    // A line that would be dropped mustn't move a counter or a timer either,
    // or the preload run would count every call twice.
    for (const name of viaConsoleByLevel[level]) {
      replace(name, (...args) => {
        if (loggerFor(level) != null) routed[name](...args);
      });
    }
  }
  // Clearing the screen would wipe the display and the lines above it.
  replace("clear", () => {});
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
    level =>
      levelNumber(level) >= logger.minLevel
        ? loggerFor(logger)->Nullable.fromOption
        : Nullable.null,
    (logger, level, message, params) =>
      logger->logAt(level, message, ~params=?params->Nullable.toOption),
  )
