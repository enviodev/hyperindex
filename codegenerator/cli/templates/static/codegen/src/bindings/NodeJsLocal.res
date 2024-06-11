type t
@module external process: t = "process"
@send external exit: (t, unit) => unit = "exit"
type exitCode = | @as(0) Success | @as(1) Failure
@send external exitWithCode: (t, exitCode) => unit = "exit"

module Util = {
  @unboxed
  type depth = Int(int) | @as(null) Null
  @unboxed
  type compact = Bool(bool) | Int(int)
  @unboxed
  type sorted = Bool(bool) | Fn((string, string) => int)
  @unboxed
  type getters = | @as(true) True | @as(false) False | @as("get") Get | @as("set") Set

  @unbox
  type inspectOptions = {
    showHidden?: bool,
    depth?: depth,
    colors?: bool,
    customInspect?: bool,
    showProxy?: bool,
    maxArrayLength?: int,
    maxStringLength?: int,
    breakLength?: int,
    @as("compact") compact?: compact,
    sorted?: sorted,
    getters?: string,
    numericSeparator?: bool,
  }

  @module("util") external inspect: ('a, inspectOptions) => string = "inspect"

  let inspectObj = a => inspect(a, {showHidden: false, depth: Null, colors: true})
}
