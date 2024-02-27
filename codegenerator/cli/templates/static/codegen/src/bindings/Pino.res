type logLevelBuiltin = [
  | #trace
  | #debug
  | #info
  | #warn
  | #error
  | #fatal
]
@genType
type logLevelUser = [
  | // NOTE: pino does better when these are all lowercase - some parts of the code lower case logs.
  #udebug
  | #uinfo
  | #uwarn
  | #uerror
]
type logLevel = [logLevelBuiltin | logLevelUser]

type pinoMessageBlob
@genType
type t = {
  trace: (. pinoMessageBlob) => unit,
  debug: (. pinoMessageBlob) => unit,
  info: (. pinoMessageBlob) => unit,
  warn: (. pinoMessageBlob) => unit,
  error: (. pinoMessageBlob) => unit,
  fatal: (. pinoMessageBlob) => unit,
}
@send external errorExn: (t, exn, pinoMessageBlob) => unit = "error"
/**
This is preferred over errorExn since it will expose the values of the error
*/
@send
external errorJsExn: (t, Js.Exn.t, pinoMessageBlob) => unit = "error"

// Bind to the 'level' property getter
@get external getLevel: t => logLevel = "level"

@ocaml.doc(`Get the available logging levels`) @get
external levels: t => 'a = "levels"

// Bind to the 'level' property setter
@set external setLevel: (t, logLevel) => unit = "level"

@ocaml.doc(`Identity function to help co-erce any type to a pino log message`)
let createPinoMessage = (message): pinoMessageBlob => Obj.magic(message)

/**
Jank solution to make logs use console log wrather than stream.write so that ink 
can render the logs statically.
*/
module Transport = {
  type t
  type optionsObject
  let makeTransportOptions: 'a => optionsObject = Obj.magic

  // NOTE: this config is pretty polymorphic - so keeping this as all optional fields.
  type rec transportTarget = {
    target?: string,
    targets?: array<transportTarget>,
    options?: optionsObject,
    levels?: Js.Dict.t<int>,
    level?: logLevel,
  }
  @module("pino")
  external make: transportTarget => t = "transport"
}

@module external makeWithTransport: Transport.t => t = "pino"

type hooks = {logMethod: (array<string>, string, logLevel) => unit}

type formatters = {
  level: (string, int) => Js.Json.t,
  bindings: Js.Json.t => Js.Json.t,
  log: Js.Json.t => Js.Json.t,
}

type serializers = {err: Js.Json.t => Js.Json.t}

type options = {
  name?: string,
  level?: logLevel,
  customLevels?: Js.Dict.t<int>,
  useOnlyCustomLevels?: bool,
  depthLimit?: int,
  edgeLimit?: int,
  mixin?: unit => Js.Json.t,
  mixinMergeStrategy?: (Js.Json.t, Js.Json.t) => Js.Json.t,
  redact?: array<string>,
  hooks?: hooks,
  formatters?: formatters,
  serializers?: serializers,
  msgPrefix?: string,
  base?: Js.Json.t,
  enabled?: bool,
  crlf?: bool,
  timestamp?: bool,
  messageKey?: string,
}

@module("pino") external make: options => t = "default"
@module("pino") external makeWithOptionsAndTransport: (options, Transport.t) => t = "default"

type childParams
let createChildParams: 'a => childParams = Obj.magic
@send external child: (t, childParams) => t = "child"

module ECS = {
  @module("@elastic/ecs-pino-format")
  external make: 'a => options = "default"
}

@module("./multistreamlogger.mjs")
external makeSyncLogger: (
  ~userLogLevel: logLevel,
  ~customLevels: Js.Dict.t<int>,
  ~logFile: option<string>,
  ~options: option<options>,
) => t = "makelogger"
