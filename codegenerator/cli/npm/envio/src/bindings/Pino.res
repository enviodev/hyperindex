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
type pinoMessageBlobWithError
@genType
type t = {
  trace: pinoMessageBlob => unit,
  debug: pinoMessageBlob => unit,
  info: pinoMessageBlob => unit,
  warn: pinoMessageBlob => unit,
  error: pinoMessageBlob => unit,
  fatal: pinoMessageBlob => unit,
}
@send external errorExn: (t, pinoMessageBlobWithError) => unit = "error"

// Bind to the 'level' property getter
@get external getLevel: t => logLevel = "level"

@ocaml.doc(`Get the available logging levels`) @get
external levels: t => 'a = "levels"

// Bind to the 'level' property setter
@set external setLevel: (t, logLevel) => unit = "level"

@ocaml.doc(`Identity function to help co-erce any type to a pino log message`)
let createPinoMessage = (message): pinoMessageBlob => Utils.magic(message)
let createPinoMessageWithError = (message, err): pinoMessageBlobWithError => {
  //See https://github.com/pinojs/pino-std-serializers for standard pino serializers
  //for common objects. We have also defined the serializer in this format in the
  // serializers type below: `type serializers = {err: Js.Json.t => Js.Json.t}`
  Utils.magic({
    "msg": message,
    "err": err,
  })
}

module Transport = {
  type t
  type optionsObject
  let makeTransportOptions: 'a => optionsObject = Utils.magic

  // NOTE: this config is pretty polymorphic - so keeping this as all optional fields.
  type rec transportTarget = {
    target?: string,
    targets?: array<transportTarget>,
    options?: optionsObject,
    levels?: dict<int>,
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
  customLevels?: dict<int>,
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

@module external make: options => t = "pino"
@module external makeWithOptionsAndTransport: (options, Transport.t) => t = "pino"

type childParams
let createChildParams: 'a => childParams = Utils.magic
@send external child: (t, childParams) => t = "child"

module ECS = {
  @module
  external make: 'a => options = "@elastic/ecs-pino-format"
}

/**
Jank solution to make logs use console log wrather than stream.write so that ink 
can render the logs statically.
*/
module MultiStreamLogger = {
  type stream = {write: string => unit}
  type multiStream = {stream: stream, level: logLevel}
  type multiStreamRes
  @module("pino") external multistream: array<multiStream> => multiStreamRes = "multistream"

  @module external makeWithMultiStream: (options, multiStreamRes) => t = "pino"

  type destinationOpts = {
    dest: string, //file path
    sync: bool,
    mkdir: bool,
  }
  @module("pino") external destination: destinationOpts => stream = "destination"

  type prettyFactoryOpts = {...options, customColors?: string}
  @module("pino-pretty")
  external prettyFactory: prettyFactoryOpts => string => string = "prettyFactory"

  let makeFormatter = logLevels => {
    prettyFactory({
      customLevels: logLevels,
      customColors: "fatal:bgRed,error:red,warn:yellow,info:green,udebug:bgBlue,uinfo:bgGreen,uwarn:bgYellow,uerror:bgRed,debug:blue,trace:gray",
    })
  }

  let makeStreams = (~userLogLevel, ~formatter, ~logFile, ~defaultFileLogLevel) => {
    let stream = {
      stream: {write: v => formatter(v)->Js.log},
      level: userLogLevel,
    }
    let maybeFileStream = logFile->Belt.Option.mapWithDefault([], dest => [
      {
        level: defaultFileLogLevel,
        stream: destination({dest, sync: false, mkdir: true}),
      },
    ])
    [stream]->Belt.Array.concat(maybeFileStream)
  }

  let make = (
    ~userLogLevel: logLevel,
    ~customLevels: dict<int>,
    ~logFile: option<string>,
    ~options: option<options>,
    ~defaultFileLogLevel,
  ) => {
    let options = switch options {
    | Some(opts) => {...opts, customLevels, level: userLogLevel}
    | None => {customLevels, level: userLogLevel}
    }
    let formatter = makeFormatter(customLevels)
    let ms = makeStreams(~userLogLevel, ~formatter, ~logFile, ~defaultFileLogLevel)->multistream

    makeWithMultiStream(options, ms)
  }
}
