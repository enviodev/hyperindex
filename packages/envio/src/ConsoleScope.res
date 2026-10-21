// What a `console` call inside user code is about, so its line carries the same
// fields as `context.log` would.
type t =
  // A handler's preload run, whose lines its run proper says again.
  | Silent
  // A batch's handlers, which run one at a time: the scope is entered once per
  // batch, and the item swapped in before each handler.
  | Item({mutable item: Internal.item, loggerFor: Internal.item => Logger.t})
  // Code that runs alongside others, such as an effect or a contract register.
  | Logger(unit => Logger.t)

type storage
@module("node:async_hooks") @new external makeStorage: unit => storage = "AsyncLocalStorage"
@send external runInStorage: (storage, t, unit => 'a) => 'a = "run"
@send external getStore: storage => Nullable.t<t> = "getStore"

// Async context costs a fixed charge per scope entered only where Node carries
// it in frames: by default from Node 24, behind a flag before. Without frames,
// any use of it makes every `await` in the process about twice as slow, so
// lines there go without the fields.
let isCheap: bool = %raw(`(function () {
  var major = Number(process.versions.node.split(".")[0]);
  var flags = process.execArgv.concat((process.env.NODE_OPTIONS || "").split(/\s+/));
  return major >= 24
    ? flags.indexOf("--no-async-context-frame") === -1
    : flags.indexOf("--experimental-async-context-frame") !== -1;
})()`)

let storage = isCheap ? Some(makeStorage()) : None

let run = (scope, f) =>
  switch storage {
  | Some(storage) => storage->runInStorage(scope, f)
  | None => f()
  }

let setItem = (scope, item) =>
  switch scope {
  | Item(scope) => scope.item = item
  | Silent | Logger(_) => ()
  }

// The logger a `console` line goes through: the scope's, or `root` outside any.
// `None` drops the line.
let loggerFor = (root: Logger.t) =>
  switch storage {
  | None => Some(root)
  | Some(storage) =>
    switch storage->getStore->Nullable.toOption {
    | None => Some(root)
    | Some(Silent) => None
    | Some(Item({item, loggerFor})) => Some(loggerFor(item))
    | Some(Logger(logger)) => Some(logger())
    }
  }

// An effect is called with its arguments only, after the calls that asked for
// it are grouped, so its scope is kept by those arguments.
let effectScopes: Utils.WeakMap.t<Internal.effectArgs, t> = Utils.WeakMap.make()

let setForEffect = (args: Internal.effectArgs, logger) =>
  if isCheap {
    effectScopes->Utils.WeakMap.set(args, Logger(logger))->ignore
  }

let runEffect = (args: Internal.effectArgs, f) =>
  switch isCheap ? effectScopes->Utils.WeakMap.get(args) : None {
  | Some(scope) => run(scope, f)
  | None => f()
  }
