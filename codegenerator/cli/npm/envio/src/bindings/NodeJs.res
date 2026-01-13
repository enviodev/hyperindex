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

module Process = {
  type t = {env: Js.Dict.t<string>, execArgv: array<string>}
  @module external process: t = "process"
}

module ChildProcess = {
  type execOptions = {
    cwd?: string,
    env?: dict<string>,
    shell?: string,
  }

  type callback = (~error: Js.null<exn>, ~stdout: string, ~stderr: string) => unit

  @module("child_process")
  external exec: (string, callback) => unit = "exec"

  @module("child_process")
  external execWithOptions: (string, execOptions, callback) => unit = "exec"
}

module Url = {
  type t
  @module("url") external fileURLToPath: t => string = "fileURLToPath"
}

module ImportMeta = {
  type t = {url: Url.t}
  @val external importMeta: t = "import.meta"
}

module Path = {
  type t

  @module("path") @variadic
  external resolve: array<string> => t = "resolve"

  @module("path") external join: (t, string) => t = "join"
  @module("path") external dirname: string => t = "dirname"

  external toString: t => string = "%identity"

  // ESM-compatible __dirname replacement
  let __dirname = dirname(Url.fileURLToPath(ImportMeta.importMeta.url))
}

module WorkerThreads = {
  // Check if we're in the main thread or a worker
  @module("worker_threads") external isMainThread: bool = "isMainThread"

  // Worker data passed from main thread
  @module("worker_threads") external workerData: Js.Nullable.t<'a> = "workerData"

  // MessagePort for communication with parent
  type messagePort
  @module("worker_threads") external parentPort: Js.Nullable.t<messagePort> = "parentPort"
  @send external postMessage: (messagePort, 'a) => unit = "postMessage"
  @send external onPortMessage: (messagePort, @as("message") _, 'a => unit) => unit = "on"

  // Worker class for spawning workers
  type worker
  type workerOptions = {workerData?: Js.Json.t, execArgv?: array<string>}

  @new @module("worker_threads")
  external makeWorker: (string, workerOptions) => worker = "Worker"

  @send external onMessage: (worker, @as("message") _, 'a => unit) => unit = "on"
  @send external onError: (worker, @as("error") _, exn => unit) => unit = "on"
  @send external onExit: (worker, @as("exit") _, int => unit) => unit = "on"
  @send external terminate: worker => promise<int> = "terminate"
  @send external workerPostMessage: (worker, 'a) => unit = "postMessage"
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
