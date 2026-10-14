// What `createSidecar(contract, {...})` returns. The entry module default
// exports it, and `envio sidecar` hands the process over to it.
type handle = {close: unit => promise<unit>}
// The entities let the read client decode bigint / BigDecimal columns exactly
// instead of learning them by introspection.
// `entry` only labels `envio_sidecar_info`.
type startOptions = {entities: array<Internal.entityConfig>, entry: string}
type runtime = {start: startOptions => promise<handle>}

// How long a signalled `envio sidecar` waits for `close()` before exiting
// anyway, so a close that never settles cannot keep a pod in Terminating. The
// runtime drains for up to ENVIO_SIDECAR_GRACE_MS (20 s by default); the 2 s
// margin lets that finish, and the 28 s cap exits ahead of the pod's 30 s
// termination grace and its SIGKILL. Read raw, not through Env: an invalid
// value already fails the runtime's own start.
let closeCapMs = (~graceMs: option<string>) => {
  let graceMs = switch graceMs->Option.flatMap(raw => raw->Int.fromString) {
  | Some(graceMs) if graceMs >= 0 => graceMs
  | _ => 20_000
  }
  Math.Int.min(graceMs, 26_000) + 2_000
}

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
        Promise.race([
          closed,
          Utils.delay(
            closeCapMs(~graceMs=NodeJs.Process.process.env->Dict.get("ENVIO_SIDECAR_GRACE_MS")),
          ),
        ])->Promise.thenResolve(() => NodeJs.process->NodeJs.exitWithCode(Success))
    }
  NodeJs.Process.onSignal("SIGTERM", close)
  NodeJs.Process.onSignal("SIGINT", close)
}

// The same loopback contract the indexer pod gives the sidecar container in
// Envio Cloud (D-003). A value the developer already set wins.
let devEnv = () => {
  let env = NodeJs.Process.process.env->Dict.copy
  [
    ("ENVIO_SIDECAR_INTERNAL_URL", "http://127.0.0.1:9901"),
    ("ENVIO_INDEXER_INTERNAL_URL", "http://127.0.0.1:9899"),
    ("ENVIO_SIDECAR_PORT", "9900"),
    ("ENVIO_GRAPHQL_URL", `${Env.Hasura.url}/v1/graphql`),
  ]->Array.forEach(((key, value)) =>
    switch env->Dict.get(key) {
    | Some(set) if set !== "" => ()
    | _ => env->Dict.set(key, value)
    }
  )
  env
}

let pipeLines = (stream: Null.t<NodeJs.ChildProcess.Stream.t>, ~print) =>
  switch stream->Null.toOption {
  | None => ()
  | Some(stream) =>
    stream->NodeJs.ChildProcess.Stream.setEncoding("utf8")
    let pending = ref("")
    stream->NodeJs.ChildProcess.Stream.onData(chunk => {
      let lines = (pending.contents ++ chunk)->String.split("\n")
      pending := lines->Array.pop->Option.getOr("")
      lines->Array.forEach(line => print(`[sidecar] ${line}`))
    })
    stream->NodeJs.ChildProcess.Stream.onEnd(() =>
      if pending.contents !== "" {
        print(`[sidecar] ${pending.contents}`)
      }
    )
  }

// `envio dev` only. Deployed, the sidecar is its own container and is never
// started from the indexer. The indexer never waits for it: a sidecar that
// fails to start or crashes costs a log line, not the run.
let startForDev = (~config: Config.t) =>
  switch config.sidecar {
  | None => ()
  | Some(_) if NodeJs.Process.process.env->Dict.get("ENVIO_SIDECAR_EXTERNAL") === Some("true") =>
    Logging.info(
      "ENVIO_SIDECAR_EXTERNAL=true: not starting the sidecar, run `envio sidecar` yourself",
    )
  | Some(_) =>
    // The Rust TUI owns the terminal; a child writing to it directly would
    // tear the frame, so its lines go through console like the indexer's.
    let pipeOutput = Tui.shouldUse()
    let child = NodeJs.ChildProcess.fork(
      NodeJs.Process.argv->Array.getUnsafe(1),
      ["sidecar"],
      {
        env: devEnv(),
        stdio: pipeOutput
          ? ["inherit", "pipe", "pipe", "ipc"]
          : ["inherit", "inherit", "inherit", "ipc"],
      },
    )
    if pipeOutput {
      child->NodeJs.ChildProcess.Child.stdout->pipeLines(~print=line => Console.log(line))
      child->NodeJs.ChildProcess.Child.stderr->pipeLines(~print=line => Console.error(line))
    }
    let exited = ref(false)
    child->NodeJs.ChildProcess.Child.onExit((code, signal) => {
      exited := true
      switch (code->Null.toOption, signal->Null.toOption) {
      | (Some(0), _) | (_, Some("SIGTERM")) | (_, Some("SIGINT")) => ()
      | (code, signal) =>
        Logging.warn(
          `The sidecar exited (${switch (code, signal) {
            | (Some(code), _) => `code ${code->Int.toString}`
            | (_, Some(signal)) => `signal ${signal}`
            | _ => "unknown reason"
            }}); the indexer keeps running. Restart \`envio dev\` to start it again.`,
        )
      }
    })
    child->NodeJs.ChildProcess.Child.onError(exn =>
      Logging.errorWithExn(exn->Utils.prettifyExn, "Failed to start the sidecar")
    )
    let stopChild = () =>
      if !exited.contents {
        child->NodeJs.ChildProcess.Child.kill("SIGTERM")->ignore
      }
    NodeJs.Process.onExit(stopChild)
    // A signal with no other listener ends the process without an `exit`
    // event. Stop the sidecar, step aside, and raise the signal again so the
    // TUI (or Node's default action) ends the indexer exactly as before.
    ["SIGINT", "SIGTERM", "SIGHUP"]->Array.forEach(signal => {
      let rec onSignal = () => {
        stopChild()
        NodeJs.Process.offSignal(signal, onSignal)
        NodeJs.Process.kill(NodeJs.Process.pid, signal)->ignore
      }
      NodeJs.Process.onSignal(signal, onSignal)
    })
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
  let handle = await runtime.start({
    entities: config->Config.getPgUserEntities,
    entry: sidecar.entry,
  })
  resolveStarted.contents(handle)
}
