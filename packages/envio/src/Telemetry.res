// Anonymous usage telemetry from a running indexer. The CLI decides whether
// anything is sent and shapes what is (packages/cli/src/telemetry); this side
// reports only what the running process alone can see. Nothing here may throw
// into the indexer or keep the process alive.

type progress = {synced: bool, eventsProcessed: float}

// Must match `ErrorClass` in the CLI, which drops any class it doesn't know.
type errorClass = [#handler | #database | #source | #rate_limited | #other]

let heartbeatIntervalMillis = 6 * 60 * 60 * 1000

type state = {
  mutable startedAt: option<float>,
  mutable features: array<string>,
  mutable getProgress: unit => option<progress>,
  mutable crashReported: bool,
  mutable startupFailure: option<errorClass>,
  mutable errorCounts: dict<int>,
}

let state = {
  startedAt: None,
  features: [],
  getProgress: () => None,
  crashReported: false,
  startupFailure: None,
  errorCounts: Dict.make(),
}

type timer
@val external setInterval: (unit => unit, int) => timer = "setInterval"
@send external unref: timer => unit = "unref"
@val @scope("process") external onExit: (@as("exit") _, int => unit) => unit = "on"

let safely = fn =>
  try fn() catch {
  | _ => ()
  }

let recordError = (errorClass: errorClass) => {
  let key = (errorClass :> string)
  state.errorCounts->Dict.set(key, state.errorCounts->Dict.get(key)->Option.getOr(0) + 1)
}

let classOfKind = (kind: ErrorHandling.kind): errorClass =>
  switch kind {
  | Handler => #handler
  | Database => #database
  | Source => #source
  | Other => #other
  }

let send = (~reason) =>
  switch state.startedAt {
  | None => ()
  | Some(startedAt) =>
    safely(() => {
      let progress = state.getProgress()
      let errors = state.errorCounts
      state.errorCounts = Dict.make()
      Core.getAddon().telemetryHeartbeat({
        reason,
        features: state.features,
        synced: progress->Option.mapOr(false, p => p.synced),
        uptimeSeconds: (Date.now() -. startedAt) /. 1000.,
        eventsProcessed: progress->Option.mapOr(0., p => p.eventsProcessed),
        errors,
      })
    })
  }

// Only what the handlers registered and the command chose; config.yaml's own
// features are read by the CLI. A split run's supervisor never loads the
// handlers, so it reports none of theirs.
let runtimeFeatures = (
  ~config: Config.t,
  ~registrationsByChainId: option<HandlerRegister.registrationsByChainId>,
  ~splitRun,
) => {
  let registrations = registrationsByChainId->Option.mapOr([], Dict.valuesToArray)
  let onEvent = registrations->Array.flatMap(r => r.onEventRegistrations)
  [
    (EnvioGlobal.value.effectsCreated > 0, "effects"),
    (onEvent->Array.some(r => r.contractRegister->Option.isSome), "contract_register"),
    (onEvent->Array.some(r => r.isWildcard), "wildcard"),
    (registrations->Array.some(r => r.onBlockRegistrations->Array.length > 0), "block_handlers"),
    (config.isDev, "dev_mode"),
    (splitRun, "split_run"),
    (config.isolated, "isolated_chains"),
  ]->Array.filterMap(((on, feature)) => on ? Some(feature) : None)
}

// The first heartbeat also tells the CLI the `start` or `dev` succeeded.
let start = (~config, ~registrationsByChainId=?, ~splitRun=false, ~getProgress) =>
  safely(() => {
    state.startedAt = Some(Date.now())
    state.features = runtimeFeatures(~config, ~registrationsByChainId, ~splitRun)
    state.getProgress = getProgress
    send(~reason="start")
    setInterval(() => send(~reason="interval"), heartbeatIntervalMillis)->unref
  })

let reportCrash = (errorClass: errorClass) =>
  if state.startedAt->Option.isSome && !state.crashReported {
    state.crashReported = true
    recordError(errorClass)
    send(~reason="crash")
  }

// Notes which startup step failed, for the command's report, and hands the
// promise back untouched: the failure still reaches whoever awaits it.
let observeStartup = (promise: promise<'a>, errorClass: errorClass) => {
  promise
  ->Promise.thenResolve(_ => ())
  ->Promise.catch(_ => {
    if state.startupFailure->Option.isNone {
      state.startupFailure = Some(errorClass)
    }
    Promise.resolve()
  })
  ->ignore
  promise
}

let finishCommand = (~errorClass: option<errorClass>) =>
  safely(() =>
    Core.getAddon().telemetryFinishCommand(
      errorClass->Option.map(c => (c :> string))->Null.fromOption,
    )
  )

// Covers every way a command the runtime runs can end, `process.exit`
// included. A crash the indexer didn't classify itself is reported here as
// `other`.
let reportOnExit = () =>
  onExit(code =>
    if code !== 0 {
      reportCrash(#other)
      finishCommand(~errorClass=Some(state.startupFailure->Option.getOr(#other)))
    } else {
      finishCommand(~errorClass=None)
    }
  )
