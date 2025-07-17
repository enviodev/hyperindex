type t
@module external process: t = "process"
@send external exit: (t, unit) => unit = "exit"
type exitCode = | @as(0) Success | @as(1) Failure
@send external exitWithCode: (t, exitCode) => unit = "exit"

module Process = {
  type t = {env: Js.Dict.t<string>}
  @module external process: t = "process"
}

module ChildProcess = {
  type execOptions = {
    cwd?: string,
    env?: dict<string>,
    shell?: string,
  }

  @module("child_process")
  external exec: (
    string,
    (~error: Js.null<exn>, ~stdout: string, ~stderr: string) => unit,
    ~options: execOptions=?,
  ) => unit = "exec"
}

module Path = {
  type t

  @module("path") @variadic
  external resolve: array<string> => t = "resolve"

  @module("path") external join: (t, string) => t = "join"

  external toString: t => string = "%identity"

  external __dirname: t = "__dirname"
}

module Fs = {
  type writeFileOptions = {
    mode?: int,
    // flag?: Flag.t,
    encoding?: string,
  }

  type mkdirOptions = {
    recursive?: bool,
    mode?: int,
  }

  module Promises = {
    @module("fs") @scope("promises")
    external writeFile: (
      ~filepath: Path.t,
      ~content: string,
      ~options: writeFileOptions=?,
    ) => promise<unit> = "writeFile"

    @module("fs") @scope("promises")
    external appendFile: (
      ~filepath: Path.t,
      ~content: string,
      ~options: writeFileOptions=?,
    ) => Js.Promise.t<unit> = "appendFile"

    @module("fs") @scope("promises")
    external access: Path.t => Js.Promise.t<unit> = "access"

    type encoding = | @as("utf8") Utf8

    @module("fs") @scope("promises")
    external readFile: (~filepath: Path.t, ~encoding: encoding) => promise<string> = "readFile"

    @module("fs") @scope("promises")
    external mkdir: (~path: Path.t, ~options: mkdirOptions=?) => Js.Promise.t<unit> = "mkdir"

    @module("fs") @scope("promises")
    external readdir: Path.t => Js.Promise.t<array<string>> = "readdir"
  }
}
