@val external processChdir: string => unit = "process.chdir"
let setEnvVar: (string, string) => unit = %raw(`(k, v) => { process.env[k] = v; }`)
let dynamicImport: string => promise<unit> = %raw(`(p) => import(p)`)

// Safety net: if the indexer crashes asynchronously (unhandled rejection
// or uncaught exception) after module load, log and exit — otherwise the
// never-resolving keepalive below would hang the process forever.
// Registered once per process; returns the listeners so we can remove
// them if the indexer exits cleanly.
let installIndexerCrashGuard: unit => unit = %raw(`() => {
  const onFatal = (label) => (err) => {
    const msg = err && err.stack ? err.stack : String(err);
    console.error("[envio] Indexer " + label + ": " + msg);
    process.exit(1);
  };
  process.on("unhandledRejection", onFatal("unhandledRejection"));
  process.on("uncaughtException", onFatal("uncaughtException"));
}`)

type command = (string, JSON.t)

let executeCommand = async (command: command) => {
  let (name, data) = command
  let get = key =>
    data
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get(key))

  switch name {
  | "migration-up" => {
      let reset =
        get("reset")
        ->Option.flatMap(JSON.Decode.bool)
        ->Option.getOr(false)
      await Migrations.runUpMigrations(~reset)
      switch get("persistedState") {
      | Some(ps) => await Core.upsertPersistedState(ps->JSON.stringify)
      | None => ()
      }
    }
  | "migration-down" => await Migrations.runDownMigrations()
  | "start-indexer" => {
      // Clear prom-client registry — metrics were registered during
      // migrations (same process), and the indexer re-registers them.
      PromClient.defaultRegister->PromClient.clear

      switch get("cwd")->Option.flatMap(JSON.Decode.string) {
      | Some(cwd) => processChdir(cwd)
      | None => ()
      }
      switch get("env")->Option.flatMap(JSON.Decode.object) {
      | Some(env) =>
        env->Dict.forEachWithKey((value, key) => {
          switch value->JSON.Decode.string {
          | Some(v) => setEnvVar(key, v)
          | None => ()
          }
        })
      | None => ()
      }
      installIndexerCrashGuard()
      switch get("indexPath")->Option.flatMap(JSON.Decode.string) {
      | Some(indexPath) => await dynamicImport(indexPath)
      | None => JsError.throwWithMessage("start-indexer: missing indexPath")
      }
      // Keep the process alive — the indexer terminates via process.exit().
      // If it crashes asynchronously instead, the guard above exits(1)
      // rather than leaving this promise hung.
      await Promise.make((_resolve, _reject) => ())
    }
  | other => JsError.throwWithMessage(`Unknown command: ${other}`)
  }
}

// Mirrors the `RunCliOutcome` enum in packages/cli/src/napi.rs:
//   {"outcome":"helpOrVersion"}        → clap printed help/version, exit 0
//   {"outcome":"ok","commands":[...]}  → drain commands in order
type runCliOutcome = {
  outcome: string,
  commands: option<array<command>>,
}

let run = async args => {
  try {
    let outcomeJson = await Core.runCli(args)
    let parsed = outcomeJson->JSON.parseOrThrow->(Utils.magic: JSON.t => runCliOutcome)
    switch parsed.outcome {
    | "helpOrVersion" => NodeJs.process->NodeJs.exitWithCode(Success)
    | "ok" =>
      let commands = parsed.commands->Option.getOr([])
      for i in 0 to commands->Array.length - 1 {
        await executeCommand(commands->Array.getUnsafe(i))
      }
    | other => JsError.throwWithMessage(`Unknown runCli outcome: ${other}`)
    }
  } catch {
  | JsExn(e) =>
    let msg = e->(Utils.magic: unknown => JsError.t)->JsError.message
    Console.error(msg)
    NodeJs.process->NodeJs.exitWithCode(Failure)
  }
}
