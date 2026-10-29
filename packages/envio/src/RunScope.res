// Which user code is running. Entered around every handler and contract
// register run, and every effect call, so a context finds the run it belongs
// to, work a run starts without awaiting still finds its own run however late
// it finishes, and `console` lines inside user code name what they're about.

type handlerRun = {
  item: Internal.item,
  checkpointId: Internal.checkpointId,
  // A preload run is silent until it resolves, and its writes are no-ops, so
  // its context stays usable after it resolves.
  isPreload: bool,
  mutable isResolved: bool,
  chainLogger: Logger.t,
  ecosystem: Ecosystem.t,
}

// Runs at fetch time, before its item has a checkpoint. The addresses it adds
// go into the fetch response's registrations.
type contractRegisterRun = {
  item: Internal.item,
  mutable isResolved: bool,
  chainLogger: Logger.t,
  ecosystem: Ecosystem.t,
  registrations: array<AddressStore.registration>,
  // Subgraph mode: the creation round the addresses it adds belong to (see
  // `AddressStore.registration.creationRound`).
  creationRound?: int,
}

// An effect call is shared by the runs that asked for it, so it is told by the
// run that triggered it.
type effectRun = {
  caller: handlerRun,
  effectName: string,
}

type t =
  | Handler(handlerRun)
  | ContractRegister(contractRegisterRun)
  | Effect(effectRun)

type storage
@module("node:async_hooks") @new external makeStorage: unit => storage = "AsyncLocalStorage"
@send external runInStorage: (storage, t, unit => 'r) => 'r = "run"
@send external runInStorage2: (storage, t, ('a, 'b) => 'r, 'a, 'b) => 'r = "run"
@send external getStore: storage => Nullable.t<t> = "getStore"

// Cheap where Node keeps async context in frames, the default from Node 24.
// Before that, using it at all makes every `await` in the process slower.
let storage = makeStorage()

let handlerLogger = (run: handlerRun) =>
  run.item->Ecosystem.loggerForItem(~ecosystem=run.ecosystem, ~logger=run.chainLogger)

let contractRegisterLogger = (run: contractRegisterRun) =>
  run.item->Ecosystem.loggerForItem(~ecosystem=run.ecosystem, ~logger=run.chainLogger)

let effectLogger = (run: effectRun) =>
  run.caller->handlerLogger->Logger.withFields({"effect": run.effectName})

let resolve = scope =>
  switch scope {
  | Handler(run) => run.isResolved = true
  | ContractRegister(run) => run.isResolved = true
  | Effect(_) => ()
  }

// Runs user code inside `scope`. The caller awaits it and calls `resolve` once
// it settles either way, rather than this wrapping it in another promise per
// run; code that throws before its first await throws here, so the await must
// enclose the call. `f` takes its arguments rather than closing over them, so a
// caller passes a function made once instead of one per run.
let enter = (scope, f: ('a, 'b) => promise<'r>, a: 'a, b: 'b) =>
  storage->runInStorage2(scope, f, a, b)

let throwResolved = (~prop, ~runName, ~logger) =>
  Utils.Error.make(
    `Impossible to access context.${prop} after the ${runName} is resolved. Make sure you didn't miss an await in the handler.`,
  )->ErrorHandling.mkLogAndRaise(~logger)

let throwOutside = (~prop) =>
  JsError.throwWithMessage(
    `Impossible to access context.${prop} outside of the handler it was passed to.`,
  )

// The handler run a `context.${prop}` call belongs to. Work a run started
// without awaiting it is caught here once the run has resolved; a preload
// run's context stays usable, since its writes are no-ops anyway.
let currentHandlerRunOrThrow = (~prop) =>
  switch storage->getStore->Nullable.toOption {
  | Some(Handler(run)) =>
    if run.isResolved && !run.isPreload {
      throwResolved(~prop, ~runName="handler", ~logger=run->handlerLogger)
    }
    run
  | Some(ContractRegister(_) | Effect(_)) | None => throwOutside(~prop)
  }

let currentContractRegisterRunOrThrow = (~prop) =>
  switch storage->getStore->Nullable.toOption {
  | Some(ContractRegister(run)) =>
    if run.isResolved {
      throwResolved(~prop, ~runName="contract register", ~logger=run->contractRegisterLogger)
    }
    run
  | Some(Handler(_) | Effect(_)) | None => throwOutside(~prop)
  }

// The logger a `console` line goes through: the scope's, or `root` outside any.
// `None` drops the line. A preload run is silent only until it resolves: work
// it started that finishes later prints like any other code.
let loggerFor = (root: Logger.t) =>
  switch storage->getStore->Nullable.toOption {
  | Some(Handler({isPreload: true, isResolved: false})) => None
  | Some(Handler({isPreload: true, isResolved: true})) => Some(root)
  | Some(Handler(run)) => Some(run->handlerLogger)
  | Some(ContractRegister(run)) => Some(run->contractRegisterLogger)
  | Some(Effect(run)) => Some(run->effectLogger)
  | None => Some(root)
  }

// An effect context carries its effect run under a symbol, so it stays out of
// what user code sees when it inspects the context.
let effectRunKey: Symbol.t = %raw(`Symbol("envio.effectRun")`)
@set_index external setEffectRun: (Internal.effectContext, Symbol.t, effectRun) => unit = ""
@get_index external getEffectRun: (Internal.effectContext, Symbol.t) => effectRun = ""

let attachEffectRun = (context, run) => context->setEffectRun(effectRunKey, run)
let effectRunOf = context => context->getEffectRun(effectRunKey)

let enterEffect = (args: Internal.effectArgs, f) =>
  storage->runInStorage(Effect(args.context->effectRunOf), f)
