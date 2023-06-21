@genType
type logLevel = [
| #trace
| #debug
| #info
| #warn
| #error
| #fatal
]

type pinoConfig = {level: logLevel}

type pinoMessageBlob
type t = {
  trace: (. pinoMessageBlob) => unit,
  debug: (. pinoMessageBlob) => unit,
  info: (. pinoMessageBlob) => unit,
  warn: (. pinoMessageBlob) => unit,
  error: (. pinoMessageBlob) => unit,
  fatal: (. pinoMessageBlob) => unit,
}

@module("pino") external make: pinoConfig => t = "default"


// Bind to the 'level' property getter
@get external getLevel: t => logLevel = "level"

@ocaml.doc(`Get the available logging levels`) @get
external levels: t => 'a = "levels"

// Bind to the 'level' property setter
@set external setLevel: (t, logLevel) => unit = "level"

@ocaml.doc(`Identity function to help co-erce any type to a pino log message`)
let createPinoMessage = (message): pinoMessageBlob => Obj.magic(message)

module Trasport = {
  type t
  @module("pino")
  external make: 'a => t = "transport"
}

@module("pino") external makeWithTransport: Trasport.t => t = "default"

type childParams
let createChildParams: 'a => childParams = Obj.magic
@send external child: (t, childParams) => t = "child"
