@val external processChdir: string => unit = "process.chdir"
let setEnvVar: (string, string) => unit = %raw(`(k, v) => { process.env[k] = v; }`)

// Crash on unhandled promise rejections with a readable error.
// ReScript exceptions compile to plain objects, not Error instances, so Node.js prints "#<Object>".
NodeJs.globalProcess->NodeJs.onUnhandledRejection(reason => {
  Logging.errorWithExn(reason->Utils.prettifyExn, "Unhandled promise rejection")
  NodeJs.process->NodeJs.exitWithCode(Failure)
})

// Wire format mirrors the Rust `executor::Command` enum — a tagged JSON
// object with a `kind` discriminator.
type startCmd = {
  reset: bool,
  cwd: string,
  env: dict<JSON.t>,
  config: JSON.t,
}
type migrateCmd = {reset: bool, config: JSON.t}
type dropSchemaCmd = {config: JSON.t}
type resolversCmd = {mode: string, cwd: string, env: dict<JSON.t>, config: JSON.t}

type command =
  | Start(startCmd)
  | Migrate(migrateCmd)
  | DropSchema(dropSchemaCmd)
  | Resolvers(resolversCmd)

let decodeCommand = (json: JSON.t): command => {
  let obj = switch json->JSON.Decode.object {
  | Some(o) => o
  | None => JsError.throwWithMessage("Invalid command payload: not an object")
  }
  let kind = switch obj->Dict.get("kind")->Option.flatMap(JSON.Decode.string) {
  | Some(k) => k
  | None => JsError.throwWithMessage("Invalid command payload: missing kind")
  }
  switch kind {
  | "start" => Start(json->(Utils.magic: JSON.t => startCmd))
  | "migrate" => Migrate(json->(Utils.magic: JSON.t => migrateCmd))
  | "drop-schema" => DropSchema(json->(Utils.magic: JSON.t => dropSchemaCmd))
  | "resolvers" => Resolvers(json->(Utils.magic: JSON.t => resolversCmd))
  | other => JsError.throwWithMessage(`Unknown command kind: ${other}`)
  }
}

let applyEnv = (env: dict<JSON.t>) =>
  env->Dict.forEachWithKey((value, key) => {
    switch value->JSON.Decode.string {
    | Some(v) => setEnvVar(key, v)
    | None => ()
    }
  })

let run = async args => {
  try {
    switch (await Core.runCli(args))->Null.toOption {
    // Rust-only command (codegen / init / stop / docker / metrics / help /
    // version / scripts) — nothing for JS to do, exit cleanly.
    | None => ()
    | Some(json) =>
      switch decodeCommand(json->JSON.parseOrThrow) {
      | Start({reset, cwd, env, config}) =>
        Config.prime(config)
        processChdir(cwd)
        applyEnv(env)
        // `envio dev` only — see ResolverProcess.startForDev. A deployment
        // runs the resolvers as their own Deployment, never from here.
        let loaded = Config.load()
        if loaded.isDev {
          let _ = await ResolverProcess.startForDev(~config=loaded, ~projectRoot=cwd)
        }
        await Main.start(~reset)
      | Migrate({reset, config}) =>
        Config.prime(config)
        await Main.migrate(~reset)
      | DropSchema({config}) =>
        Config.prime(config)
        await Main.dropSchema()
      | Resolvers({mode, cwd, env, config}) =>
        Config.prime(config)
        processChdir(cwd)
        applyEnv(env)
        switch mode {
        | "manifest" => await ResolverProcess.writeManifest(~config=Config.load(), ~projectRoot=cwd)
        | "metadata" =>
          let handlerUrl = switch Env.Resolvers.publicUrl() {
          | Some(url) => url
          | None =>
            JsError.throwWithMessage(
              "ENVIO_RESOLVERS_PUBLIC_URL is not set. It is the URL Hasura posts to and is baked into every action, so the metadata cannot be printed without it.",
            )
          }
          let metadata = await ResolverProcess.metadataJson(
            ~config=Config.load(),
            ~projectRoot=cwd,
            ~handlerUrl,
          )
          // stdout, so it pipes into `hasura metadata apply` or `jq` rather
          // than being buried in the log stream.
          Console.log(JSON.stringify(metadata, ~space=2))
        | "migrate" =>
          let {applied, reasons} = await ResolverProcess.migrate(
            ~config=Config.load(),
            ~projectRoot=cwd,
          )
          Logging.info(
            applied
              ? `Updated Hasura to match these resolvers: ${reasons->Array.join("; ")}`
              : "Hasura already matches these resolvers; nothing to update",
          )
        // Serving keeps the event loop alive on its own, so returning here
        // leaves the process running rather than exiting.
        | _ =>
          let running = await ResolverProcess.serve(~config=Config.load(), ~projectRoot=cwd)
          running->ResolverProcess.handleSignals
        }
      }
    }
  } catch {
  | Main.FatalError(_) =>
    // Already logged with full context by Main.start's onError; just exit.
    NodeJs.process->NodeJs.exitWithCode(Failure)
  | exn =>
    // Log just the exception's own message — wrapping it in "Failed at
    // initialization" and pino's err serializer buries the real cause under
    // a nested `err: { type, message, stack, ... }` block.
    let message = switch exn->JsExn.anyToExnInternal {
    | JsExn(e) => e->JsExn.message->Option.getOr("Failed at initialization")
    | _ => "Failed at initialization"
    }
    Logging.error(message)
    NodeJs.process->NodeJs.exitWithCode(Failure)
  }
}
