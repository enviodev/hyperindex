// Which user code is running. Entered around every handler and contract
// register run, so the run's context finds its item and checkpoint, and so
// work a run starts without awaiting still finds its own run, however late it
// finishes. `console` lines inside user code are routed by the same scope.

type kind =
  | @as("handler") Handler
  // A handler's preload run: silent until it resolves, and its writes are
  // no-ops, so its context stays usable after it resolves.
  | @as("preload") Preload
  | @as("contractRegister") ContractRegister

type run = {
  kind: kind,
  item: Internal.item,
  // A contract register runs at fetch time, before its item has a checkpoint,
  // and has nothing to write under one.
  checkpointId: option<Internal.checkpointId>,
  mutable isResolved: bool,
  loggerFor: Internal.item => Logger.t,
}

@unboxed
type t =
  | Run(run)
  // An effect call, which a group of runs share, so it has a logger rather
  // than a run of its own.
  | Effect(unit => Logger.t)

type storage
@module("node:async_hooks") @new external makeStorage: unit => storage = "AsyncLocalStorage"
@send external runInStorage: (storage, t, unit => 'a) => 'a = "run"
@send external runInStorage1: (storage, t, 'a => 'r, 'a) => 'r = "run"
@send external getStore: storage => Nullable.t<t> = "getStore"

// Cheap where Node keeps async context in frames, the default from Node 24.
// Before that, using it at all makes every `await` in the process slower.
let storage = makeStorage()

let enter = (scope, f) => storage->runInStorage(scope, f)

// Runs user code as a run of its own and marks the run resolved once it
// settles either way. Code that throws before its first await rejects like
// code that throws after. `f` takes its argument rather than closing over it,
// so a hot caller passes a function made once instead of one per run.
let run = async (~kind, ~item, ~checkpointId=?, ~loggerFor, f: 'a => promise<'r>, arg: 'a) => {
  let run = {kind, item, checkpointId, isResolved: false, loggerFor}
  switch await storage->runInStorage1(Run(run), f, arg) {
  | exception exn =>
    run.isResolved = true
    throw(exn)
  | result =>
    run.isResolved = true
    result
  }
}

// The run a `context.${prop}` call belongs to. Work a run started without
// awaiting it is caught here once the run has resolved; a preload run's
// context stays usable, since its writes are no-ops anyway.
let currentRunOrThrow = (~prop) =>
  switch storage->getStore->Nullable.toOption {
  | Some(Run(run)) =>
    if run.isResolved && run.kind !== Preload {
      let runName = switch run.kind {
      | ContractRegister => "contract register"
      | Handler | Preload => "handler"
      }
      Utils.Error.make(
        `Impossible to access context.${prop} after the ${runName} is resolved. Make sure you didn't miss an await in the handler.`,
      )->ErrorHandling.mkLogAndRaise(~logger=run.loggerFor(run.item))
    }
    run
  | Some(Effect(_)) | None =>
    JsError.throwWithMessage(
      `Impossible to access context.${prop} outside of the handler it was passed to.`,
    )
  }

// The logger a `console` line goes through: the scope's, or `root` outside any.
// `None` drops the line. A preload run is silent only until it resolves: work
// it started that finishes later prints like any other code.
let loggerFor = (root: Logger.t) =>
  switch storage->getStore->Nullable.toOption {
  | Some(Run({kind: Preload, isResolved: false})) => None
  | Some(Run({kind: Preload, isResolved: true})) => Some(root)
  | Some(Run({kind: Handler | ContractRegister, item, loggerFor})) => Some(loggerFor(item))
  | Some(Effect(logger)) => Some(logger())
  | None => Some(root)
  }

// The logger of an effect call, kept by its context: the effect runs with its
// arguments only, after the calls that asked for it are grouped, and its
// `context.log` is read off that same context.
let effectLoggers: Utils.WeakMap.t<Internal.effectContext, unit => Logger.t> = Utils.WeakMap.make()

let setEffectLogger = (context, logger) => effectLoggers->Utils.WeakMap.set(context, logger)->ignore

let effectLogger = context => effectLoggers->Utils.WeakMap.unsafeGet(context)

let enterEffect = (args: Internal.effectArgs, f) =>
  switch effectLoggers->Utils.WeakMap.get(args.context) {
  | Some(logger) => enter(Effect(logger), f)
  | None => f()
  }
