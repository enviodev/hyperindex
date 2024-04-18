type t
@module external process: t = "process"
@send external exit: (t, unit) => unit = "exit"
type exitCode = | @as(0) Succes | @as(1) Failure
@send external exitWithCode: (t, exitCode) => unit = "exit"
