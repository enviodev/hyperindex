// What `createSidecar(contract, {...})` returns. The entry module default
// exports it, and `envio sidecar` hands the process over to it.
type handle = {close: unit => promise<unit>}
// The entities let the read client decode bigint / BigDecimal columns exactly
// instead of learning them by introspection.
type startOptions = {entities: array<Internal.entityConfig>}
type runtime = {start: startOptions => promise<handle>}

// A close that never settles must not keep a pod in Terminating forever.
let closeGraceMs = 5_000

let runtimeOf = (entryModule: unknown): option<runtime> => {
  let default = (
    entryModule->(Utils.magic: unknown => {"default": Nullable.t<{"start": unknown}>})
  )["default"]
  switch default->Nullable.toOption {
  | Some(candidate) if typeof(candidate["start"]) === #function =>
    Some(candidate->(Utils.magic: {"start": unknown} => runtime))
  | _ => None
  }
}

let loadRuntimeOrThrow = async (~entry) => {
  let entryModule = try await Utils.importPath(
    HandlerLoader.toAbsolutePath(entry)->NodeJs.Url.pathToFileURL->NodeJs.Url.toString,
  ) catch {
  | exn =>
    JsError.throwWithMessage(
      `Failed to load the sidecar entry '${entry}' named by \`sidecar.entry\`. Cause: ${exn
        ->Utils.prettifyExn
        ->Obj.magic}`,
    )
  }
  switch entryModule->runtimeOf {
  | Some(runtime) => runtime
  | None =>
    JsError.throwWithMessage(
      `The sidecar entry '${entry}' must default-export the result of createSidecar(contract, {...}): \`export default createSidecar(...)\`.`,
    )
  }
}

// Installed before the entry is even loaded: until Node has a listener, a
// SIGTERM takes the default action and kills the process, so a pod stopped
// while its sidecar starts would skip `close`. A signal that lands early waits
// for `start` and closes the sidecar once it is up.
let closeOnSignals = (started: promise<handle>) => {
  let closing = ref(false)
  let close = () =>
    if !closing.contents {
      closing := true
      Logging.info("Stopping the sidecar")
      let closed =
        started
        ->Promise.then(handle => handle.close())
        ->Promise.catch(exn => {
          Logging.errorWithExn(exn->Utils.prettifyExn, "The sidecar failed to close cleanly")
          Promise.resolve()
        })
      let _ =
        Promise.race([closed, Utils.delay(closeGraceMs)])->Promise.thenResolve(() =>
          NodeJs.process->NodeJs.exitWithCode(Success)
        )
    }
  NodeJs.Process.onSignal("SIGTERM", close)
  NodeJs.Process.onSignal("SIGINT", close)
}

let run = async (~config: Config.t) => {
  let sidecar = switch config.sidecar {
  | Some(sidecar) => sidecar
  | None => JsError.throwWithMessage("`envio sidecar` needs a `sidecar:` key in config.yaml.")
  }
  let resolveStarted = ref(_ => ())
  let started = Promise.make((resolve, _) => resolveStarted := resolve)
  started->closeOnSignals
  HandlerLoader.registerTsHooks()
  let runtime = await loadRuntimeOrThrow(~entry=sidecar.entry)
  let handle = await runtime.start({entities: config->Config.getPgUserEntities})
  resolveStarted.contents(handle)
}
