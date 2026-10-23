// What a `console` call inside user code is about, so its line carries the same
// fields as `context.log` would.
type t =
  // A handler's preload run, whose lines its run proper says again.
  | Silent({mutable isOver: bool})
  // A batch's handlers, which run one at a time: the scope is entered once per
  // batch, and the item swapped in before each handler.
  | Item({mutable item: Internal.item, loggerFor: Internal.item => Logger.t, mutable isOver: bool})
  // Code that runs alongside others, such as an effect or a contract register.
  | Logger(unit => Logger.t)

type storage
@module("node:async_hooks") @new external makeStorage: unit => storage = "AsyncLocalStorage"
@send external runInStorage: (storage, t, unit => 'a) => 'a = "run"
@send external getStore: storage => Nullable.t<t> = "getStore"

// Cheap where Node keeps async context in frames, the default from Node 24.
// Before that, using it at all makes every `await` in the process slower.
let storage = makeStorage()

let run = (scope, f) => storage->runInStorage(scope, f)

let finish = scope =>
  switch scope {
  | Silent(scope) => scope.isOver = true
  | Item(scope) => scope.isOver = true
  | Logger(_) => ()
  }

// Code a run starts can outlive it, in a timer or a promise nobody awaits. Its
// lines then go to the root logger, rather than being dropped for good or
// named after whichever item the batch ended on.
let runToEnd = async (scope, f) => {
  let result = try await run(scope, f) catch {
  | exn =>
    scope->finish
    throw(exn)
  }
  scope->finish
  result
}

let setItem = (scope, item) =>
  switch scope {
  | Item(scope) => scope.item = item
  | Silent(_) | Logger(_) => ()
  }

// The logger a `console` line goes through: the scope's, or `root` outside any.
// `None` drops the line.
let loggerFor = (root: Logger.t) =>
  switch storage->getStore->Nullable.toOption {
  | Some(Silent({isOver: false})) => None
  | Some(Item({isOver: false, item, loggerFor})) => Some(loggerFor(item))
  | Some(Logger(logger)) => Some(logger())
  | None | Some(Silent({isOver: true})) | Some(Item({isOver: true})) => Some(root)
  }

// An effect is called with its arguments only, after the calls that asked for
// it are grouped, so its scope is kept by those arguments.
let effectScopes: Utils.WeakMap.t<Internal.effectArgs, t> = Utils.WeakMap.make()

let setForEffect = (args: Internal.effectArgs, logger) =>
  effectScopes->Utils.WeakMap.set(args, Logger(logger))->ignore

let runEffect = (args: Internal.effectArgs, f) =>
  switch effectScopes->Utils.WeakMap.get(args) {
  | Some(scope) => run(scope, f)
  | None => f()
  }
