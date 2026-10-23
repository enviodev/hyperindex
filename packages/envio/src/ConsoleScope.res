// What a `console` call inside user code is about, so its line carries the same
// fields as `context.log` would.

// One handler run. Entered around each run, so work the run starts without
// awaiting it still finds its own run, however late it finishes.
type handlerFrame = {
  item: Internal.item,
  checkpointId: Internal.checkpointId,
  isPreload: bool,
  mutable isResolved: bool,
  loggerFor: Internal.item => Logger.t,
}

@unboxed
type t =
  | Handler(handlerFrame)
  // Code that runs alongside others, such as an effect or a contract register.
  | Logger(unit => Logger.t)

type storage
@module("node:async_hooks") @new external makeStorage: unit => storage = "AsyncLocalStorage"
@send external runInStorage: (storage, t, unit => 'a) => 'a = "run"
@send external getStore: storage => Nullable.t<t> = "getStore"
@send external runInStorage2: (storage, t, ('a, 'b) => 'c, 'a, 'b) => 'c = "run"

// Cheap where Node keeps async context in frames, the default from Node 24.
// Before that, using it at all makes every `await` in the process slower.
let storage = makeStorage()

let run = (scope, f) => storage->runInStorage(scope, f)

// `run` with the callback's arguments passed through, so a hot caller can hand
// it a function made once rather than a closure per call.
let run2 = (scope, f, a, b) => storage->runInStorage2(scope, f, a, b)

let current = () => storage->getStore

// The logger a `console` line goes through: the scope's, or `root` outside any.
// `None` drops the line. A preload run is silent only until it resolves: work
// it started that finishes later prints like any other code.
let loggerFor = (root: Logger.t) =>
  switch storage->getStore->Nullable.toOption {
  | Some(Handler({isPreload: true, isResolved: false})) => None
  | Some(Handler({isPreload: true, isResolved: true})) => Some(root)
  | Some(Handler({isPreload: false, item, loggerFor})) => Some(loggerFor(item))
  | Some(Logger(logger)) => Some(logger())
  | None => Some(root)
  }

// The logger of an effect call, kept by its context: the effect runs with its
// arguments only, after the calls that asked for it are grouped, and its
// `context.log` is read off that same context.
let effectLoggers: Utils.WeakMap.t<Internal.effectContext, unit => Logger.t> = Utils.WeakMap.make()

let setEffectLogger = (context, logger) => effectLoggers->Utils.WeakMap.set(context, logger)->ignore

let effectLogger = context => effectLoggers->Utils.WeakMap.unsafeGet(context)

let runEffect = (args: Internal.effectArgs, f) =>
  switch effectLoggers->Utils.WeakMap.get(args.context) {
  | Some(logger) => run(Logger(logger), f)
  | None => f()
  }
