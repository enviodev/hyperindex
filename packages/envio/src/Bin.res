@val external processChdir: string => unit = "process.chdir"
let setEnvVar: (string, string) => unit = %raw(`(k, v) => { process.env[k] = v; }`)
let dynamicImport: string => promise<unit> = %raw(`(p) => import(p)`)

type command = (string, JSON.t)

let executeCommand = async (command: command) => {
  let (name, data) = command
  let get = key =>
    data
    ->JSON.Decode.object
    ->Option.flatMap(d => d->Dict.get(key))

  // Rust embeds the resolved config in each command that needs it, so
  // `Config.fromConfigView()` calls inside migrations / the indexer module
  // skip the `getConfigJson` NAPI round-trip.
  switch get("config") {
  | Some(configJson) => Config.prime(configJson)
  | None => ()
  }

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
      switch get("indexPath")->Option.flatMap(JSON.Decode.string) {
      | Some(indexPath) => await dynamicImport(indexPath)
      | None => JsError.throwWithMessage("start-indexer: missing indexPath")
      }
      // Keep the process alive — the indexer terminates via process.exit().
      await Promise.make((_resolve, _reject) => ())
    }
  | other => JsError.throwWithMessage(`Unknown command: ${other}`)
  }
}

// Rust returns a JSON array of `[name, data]` commands. An empty array means
// there's nothing for JS to do — we fall out of the loop and the Node process
// exits naturally with code 0 (covers `--help`/`--version` and Rust-only
// commands like `envio codegen` / `envio init`).
let run = async args => {
  try {
    let commandsJson = await Core.runCli(args)
    let commands = commandsJson->JSON.parseOrThrow->(Utils.magic: JSON.t => array<command>)
    for i in 0 to commands->Array.length - 1 {
      await executeCommand(commands->Array.getUnsafe(i))
    }
  } catch {
  | exn =>
    Console.error(exn->Utils.prettifyExn)
    NodeJs.process->NodeJs.exitWithCode(Failure)
  }
}
