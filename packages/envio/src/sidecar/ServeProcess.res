// `envio dev` with ENVIO_SERVE_BIN: runs envio serve beside the indexer, the
// GraphQL server Envio Cloud runs in place of Hasura, with the `resolvers:` as
// its actions.

let isEnabled = (~env) =>
  switch env->Dict.get("ENVIO_SERVE_BIN") {
  | Some(bin) => bin !== ""
  | None => false
  }

// Hasura holds 8080 when it runs.
let port = (~env, ~hasuraEnabled) =>
  switch env->Dict.get("ENVIO_SERVE_PORT")->Option.flatMap(raw => raw->Int.fromString) {
  | Some(port) => port
  | None => hasuraEnabled ? 8090 : 8080
  }

let graphqlUrl = (~env, ~hasuraEnabled) =>
  `http://127.0.0.1:${port(~env, ~hasuraEnabled)->Int.toString}/v1/graphql`

let actionsFile = ".envio/actions.json"

// Serve substitutes the `{{VAR}}` and `value_from_env` from its own env, so
// the file holds no address and no secret.
let actionsMetadata = (~config: Config.t, ~withSecret) =>
  ResolverActions.build(
    config.resolvers,
    config.resolverTypes,
    {
      sidecarUrl: "{{ENVIO_SIDECAR_RESOLVERS_URL}}",
      secret: ?(withSecret ? Some({ResolverActions.fromEnv: "ENVIO_RESOLVER_SECRET"}) : None),
    },
  )

// The dev fallbacks `Env.Db` resolved are not in the environment, so serve
// gets them spelled out. Serve runs on the host like the sidecar, so it
// reaches the sidecar on loopback whatever Hasura was told.
let childEnv = (~env, ~actionsPath) => {
  let env = env->Dict.copy
  [
    ("ENVIO_PG_HOST", Env.Db.host),
    ("ENVIO_PG_PORT", Env.Db.port->Int.toString),
    ("ENVIO_PG_USER", Env.Db.user),
    ("ENVIO_PG_PASSWORD", Env.Db.password),
    ("ENVIO_PG_DATABASE", Env.Db.database),
    ("ENVIO_PG_SCHEMA", Env.Db.publicSchema),
    ("HASURA_GRAPHQL_ADMIN_SECRET", Env.Hasura.secret),
  ]->Array.forEach(((key, value)) =>
    switch env->Dict.get(key) {
    | Some(set) if set !== "" => ()
    | _ => env->Dict.set(key, value)
    }
  )
  let sidecarPort = env->Dict.get("ENVIO_SIDECAR_PORT")->Option.getOr("9900")
  env->Dict.set("ENVIO_SIDECAR_RESOLVERS_URL", `http://127.0.0.1:${sidecarPort}`)
  switch actionsPath {
  | Some(path) => env->Dict.set("ENVIO_SERVE_ACTIONS_PATH", path)
  | None => ()
  }
  env
}

let args = (~env, ~cwd, ~port) => [
  "--directory",
  cwd,
  "--config",
  switch env->Dict.get("ENVIO_CONFIG") {
  | Some(config) if config !== "" => config
  | _ => "config.yaml"
  },
  "--host",
  "127.0.0.1",
  "--port",
  port->Int.toString,
]

let started = ref(false)

// Called once the indexer's tables exist: serve refuses to start without them.
let startForDev = async (~config: Config.t) => {
  let env = NodeJs.Process.process.env
  let hasResolvers = config.resolvers->Dict.keysToArray->Array.length > 0
  switch env->Dict.get("ENVIO_SERVE_BIN") {
  | _ if started.contents => ()
  | None | Some("") =>
    if hasResolvers && !Env.Hasura.enabled {
      Logging.warn(
        "resolvers: are declared, but ENVIO_HASURA=false and ENVIO_SERVE_BIN is unset, so no GraphQL server publishes them.",
      )
    }
  | Some(bin) =>
    started := true
    let cwd = NodeJs.Process.cwd()
    let actionsPath = if hasResolvers {
      let path = NodeJs.Path.resolve([cwd, actionsFile])->NodeJs.Path.toString
      await NodeJs.Fs.Promises.mkdir(
        ~path=NodeJs.Path.resolve([cwd, ".envio"]),
        ~options={recursive: true},
      )
      await NodeJs.Fs.Promises.writeFile(
        ~filepath=NodeJs.Path.resolve([path]),
        ~content=actionsMetadata(~config, ~withSecret=Env.Sidecar.resolverSecret->Option.isSome)
        ->JSON.stringify(~space=2),
      )
      Some(path)
    } else {
      None
    }
    let port = port(~env, ~hasuraEnabled=Env.Hasura.enabled)
    let pipeOutput = Tui.shouldUse()
    let child = NodeJs.ChildProcess.spawn(
      bin,
      args(~env, ~cwd, ~port),
      {
        cwd,
        env: childEnv(~env, ~actionsPath),
        stdio: pipeOutput ? ["ignore", "pipe", "pipe"] : ["ignore", "inherit", "inherit"],
      },
    )
    if pipeOutput {
      child
      ->NodeJs.ChildProcess.Child.stdout
      ->ChildOutput.pipeLines(~label="serve", ~print=line => Console.log(line))
      child
      ->NodeJs.ChildProcess.Child.stderr
      ->ChildOutput.pipeLines(~label="serve", ~print=line => Console.error(line))
    }
    child->NodeJs.ChildProcess.Child.onError(exn =>
      Logging.errorWithExn(exn->Utils.prettifyExn, `Failed to start envio serve from ${bin}`)
    )
    child->NodeJs.ChildProcess.Child.onExit((code, signal) =>
      switch (code->Null.toOption, signal->Null.toOption) {
      | (Some(0), _) | (_, Some("SIGTERM")) | (_, Some("SIGINT")) => ()
      | (code, _) =>
        Logging.warn(
          `envio serve exited${switch code {
            | Some(code) => ` with code ${code->Int.toString}`
            | None => ""
            }}; the indexer keeps running.`,
        )
      }
    )
    ["SIGINT", "SIGTERM", "SIGHUP"]->Array.forEach(signal =>
      NodeJs.Process.onSignal(signal, () => child->NodeJs.ChildProcess.Child.kill("SIGTERM")->ignore)
    )
    Logging.info(
      `envio serve: GraphQL at http://localhost:${port->Int.toString}/v1/graphql${hasResolvers
          ? ` with ${config.resolvers->Dict.keysToArray->Array.length->Int.toString} resolvers`
          : ""}`,
    )
  }
}

// Serve is a convenience beside the indexer: failing to start it is logged,
// never fatal.
let launchForDev = (~config) =>
  startForDev(~config)
  ->Promise.catch(exn => {
    Logging.errorWithExn(exn->Utils.prettifyExn, "Failed to start envio serve")
    Promise.resolve()
  })
  ->Promise.ignore
