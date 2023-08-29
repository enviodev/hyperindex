// This file contains 'UserLogging' whereas the Logging file is for `SystemLogging` (the internal logs of our system).
//    TODO: improve file stracture and be more precise with what we expose to our users inside their indexers.

// TODO: create dynamic bindings to these functions from typescript so that users can use them directly without needing to pass stringns to these functions
@genType
type userLogger = {
  // debug: Pino.pinoMessageBlob => unit,
  // info: Pino.pinoMessageBlob => unit,
  // warn: Pino.pinoMessageBlob => unit,
  // error: Pino.pinoMessageBlob => unit,
  /// I decided that a string would be the most friendly to the user. Of course, any type can be passed to a log.
  //     To use the version of this function that can take any argument, use the non-variant version of these functions.
  debug: string => unit,
  info: string => unit,
  warn: string => unit,
  error: string => unit,
  errorWithExn: (option<Js.Exn.t>, string) => unit,
}

// NOTE: We have these functions below as an alternative since then we can pass in any type as a log.
//       This is a restriction of rescript. `'pinoMessageBlob` is an unbound type, and unbound types cannot work in a struct, such as `userLogger`.
@send
external debug: (userLogger, 'pinoMessageBlob) => unit = "debug"
@send
external info: (userLogger, 'pinoMessageBlob) => unit = "info"
@send
external warn: (userLogger, 'pinoMessageBlob) => unit = "warn"
@send
external error: (userLogger, 'pinoMessageBlob) => unit = "error"
@send
external errorWithExn: (userLogger, option<Js.Exn.t>, 'pinoMessageBlob) => unit = "errorWithExn"

// NOTE: gentype doesn't generate type interfaces on `external`s so this is a hack to get gentype to work.
@genType
let debug = debug
@genType
let info = info
@genType
let warn = warn
@genType
let error = error
@genType
let errorWithExn = errorWithExn
