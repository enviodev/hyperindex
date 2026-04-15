type t
@module external process: t = "process"
@send external exit: (t, unit) => unit = "exit"
type exitCode = | @as(0) Success | @as(1) Failure
@send external exitWithCode: (t, exitCode) => unit = "exit"
// Use @val to access the global `process` object for EventEmitter methods like `on`.
// The @module binding above compiles to `import * as Process from "process"` (a namespace import),
// which exposes named exports (exit, cwd) but not EventEmitter prototype methods (on, off, emit).
@val external globalProcess: t = "process"
@send external onUnhandledRejection: (t, @as("unhandledRejection") _, exn => unit) => unit = "on"

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
  type t = {env: dict<string>, execArgv: array<string>}
  @module external process: t = "process"
  @module("process") external cwd: unit => string = "cwd"
  @get external execPath: t => string = "execPath"
}

module ChildProcess = {
  type execOptions = {
    cwd?: string,
    env?: dict<string>,
    shell?: string,
  }

  type callback = (~error: Null.t<exn>, ~stdout: string, ~stderr: string) => unit

  @module("child_process")
  external exec: (string, callback) => unit = "exec"

  @module("child_process")
  external execWithOptions: (string, execOptions, callback) => unit = "exec"

  // `encoding` is mandatory: when omitted Node defaults to "buffer" and
  // returns Buffer instances on stdout/stderr, which would silently violate
  // the `string` typing below. Callers must pass "utf8" (or similar) so the
  // typed result is accurate.
  type spawnSyncOptions = {
    cwd?: string,
    env?: dict<string>,
    encoding: string,
    maxBuffer?: int,
  }

  // `status` is null when the child is killed by a signal before exiting; we
  // treat null-or-nonzero as failure. `error` is set when the process itself
  // couldn't be spawned (e.g., command not on PATH) — and Node leaves the
  // field `undefined` (not `null`) on success, so we use `Nullable.t` which
  // accepts both.
  type spawnSyncResult = {
    status: Nullable.t<int>,
    stdout: string,
    stderr: string,
    error: Nullable.t<exn>,
  }

  @module("child_process")
  external spawnSync: (string, array<string>, spawnSyncOptions) => spawnSyncResult = "spawnSync"
}

module Url = {
  type t
  @module("url") external fileURLToPath: t => string = "fileURLToPath"
  @module("url") external fileURLToPathFromString: string => string = "fileURLToPath"
  // Convert a file path to a file:// URL string (for dynamic imports)
  @module("url") external pathToFileURL: string => t = "pathToFileURL"
  @send external toString: t => string = "toString"
}

module ImportMeta = {
  type t = {url: Url.t}
  @val external importMeta: t = "import.meta"
  // Get import.meta.url as string for module registration
  @val external url: string = "import.meta.url"
  // Resolve module specifier to file:// URL
  @val external resolve: string => string = "import.meta.resolve"
}

module Module = {
  // Register ESM loader hooks (e.g., for TypeScript support via tsx)
  @module("node:module") external register: (string, string) => unit = "register"
}

module Path = {
  type t

  @module("path") @variadic
  external resolve: array<string> => t = "resolve"

  @module("path") external join: (t, string) => t = "join"
  @module("path") external dirname: string => t = "dirname"

  external toString: t => string = "%identity"

  // ESM-compatible __dirname replacement - accepts importMeta from calling file
  let getDirname = (importMeta: ImportMeta.t) => dirname(Url.fileURLToPath(importMeta.url))
}

module WorkerThreads = {
  // Check if we're in the main thread or a worker
  @module("worker_threads") external isMainThread: bool = "isMainThread"

  // Worker data passed from main thread
  @module("worker_threads") external workerData: Nullable.t<'a> = "workerData"

  // MessagePort for communication with parent
  type messagePort
  @module("worker_threads") external parentPort: Nullable.t<messagePort> = "parentPort"
  @send external postMessage: (messagePort, 'a) => unit = "postMessage"
  @send external onPortMessage: (messagePort, @as("message") _, 'a => unit) => unit = "on"

  // Worker class for spawning workers
  type worker
  type workerOptions = {
    workerData?: JSON.t,
    execArgv?: array<string>,
    env?: dict<string>,
  }

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
    ) => promise<unit> = "appendFile"

    @module("fs") @scope("promises")
    external access: Path.t => promise<unit> = "access"

    type encoding = | @as("utf8") Utf8

    @module("fs") @scope("promises")
    external readFile: (~filepath: Path.t, ~encoding: encoding) => promise<string> = "readFile"

    @module("fs") @scope("promises")
    external mkdir: (~path: Path.t, ~options: mkdirOptions=?) => promise<unit> = "mkdir"

    @module("fs") @scope("promises")
    external readdir: Path.t => promise<array<string>> = "readdir"
  }
}
