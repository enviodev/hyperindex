// What `envio resolvers` runs once the Rust CLI hands over: find the module
// named by `resolvers:` in config.yaml, import it so its declarations register,
// then either write the artefacts the image carries or serve them.
//
// Declaring is registering, so importing the module is the whole of "loading
// the resolvers" -- the same way importing a handler module registers its
// handlers.

type manifestBundle = {manifest: JSON.t, sdl: string}

@module("./index.js")
external buildRegisteredManifest: unit => manifestBundle = "buildRegisteredManifest"

@module("./index.js")
external getRegisteredResolvers: unit => array<unknown> = "getRegisteredResolvers"

type schemaNames = {entities: array<string>, enums: array<string>}

@module("./collisions.js")
external checkCollisions: (JSON.t, schemaNames) => unit = "checkCollisions"

// Only the entities and enums serve builds its schema from, which is what
// decides whether a custom name is already taken.
let schemaNamesOf = (config: Config.t) => {
  entities: config->Config.getPgUserEntities->Array.map(entity => entity.name),
  enums: config.allEnums->Array.map(enumConfig => enumConfig.name),
}

type pool

type poolOptions = {
  entities: dict<Internal.entityConfig>,
  pgSchema: string,
}

@module("./db.js")
external createResolverPoolFromEnv: poolOptions => pool = "createResolverPoolFromEnv"

@send external endPool: pool => promise<unit> = "end"

type server = {port: int, close: unit => promise<unit>}

type serverOptions = {
  resolvers: array<unknown>,
  pool: pool,
  port?: int,
  exposeErrors?: bool,
}

@module("./server.js")
external startResolverServer: serverOptions => promise<server> = "startResolverServer"

// The resolver module is the user's TypeScript. Registering tsx is what makes
// it importable; the throw means it is already registered, which is the case
// under `--import tsx` and in tests.
try {
  NodeJs.Module.register("tsx/esm", NodeJs.ImportMeta.url)
} catch {
| _ => ()
}

let toImportUrl = (~projectRoot, ~relativePath) =>
  NodeJs.Url.pathToFileURL(
    NodeJs.Path.resolve([projectRoot, relativePath])->NodeJs.Path.toString,
  )->NodeJs.Url.toString

let loadOrThrow = async (~projectRoot, ~relativePath) =>
  switch await Utils.importPath(toImportUrl(~projectRoot, ~relativePath)) {
  | _ => ()
  | exception exn =>
    let cause = switch exn->Utils.prettifyExn {
    | JsExn(e) => e->JsExn.message->Option.getOr("unknown error")
    | _ => "unknown error"
    }
    JsError.throwWithMessage(
      `Failed to load the resolvers module '${relativePath}' named by \`resolvers:\` in config.yaml. Cause: ${cause}`,
    )
  }

// Emitted whether or not the project declares any, so nothing downstream needs
// a "file missing" branch. An empty manifest is still a manifest serve can
// parse -- it registers no custom fields rather than refusing to start.
let emptyManifest: JSON.t = %raw(`{ schemaVersion: 1, resolvers: [], types: [] }`)

let writeManifest = async (~config: Config.t, ~projectRoot) => {
  let {manifest, sdl} = switch config.resolvers {
  | None => {manifest: emptyManifest, sdl: ""}
  | Some(relativePath) =>
    await loadOrThrow(~projectRoot, ~relativePath)
    let bundle = buildRegisteredManifest()
    checkCollisions(bundle.manifest, schemaNamesOf(config))
    bundle
  }

  let dir = NodeJs.Path.resolve([projectRoot, ".envio"])
  await NodeJs.Fs.Promises.mkdir(~path=dir, ~options={recursive: true})
  // Pretty-printed: `envio dev` diffs it, and so do the people reviewing what
  // an image is about to publish.
  await NodeJs.Fs.Promises.writeFile(
    ~filepath=dir->NodeJs.Path.join("resolvers.json"),
    ~content=JSON.stringify(manifest, ~space=2) ++ "\n",
  )
  await NodeJs.Fs.Promises.writeFile(
    ~filepath=dir->NodeJs.Path.join("resolvers.graphql"),
    ~content=sdl,
  )
}

@val @scope("process") external onSignal: (string, unit => unit) => unit = "on"

// Node closes the server but leaves keep-alive connections to time out on
// their own, and serve holds those open by design. Bounded so a rolling
// update can't be held up by an idle socket.
let closeGracePeriodMs = 5000

type running = {server: server, pool: pool, shutdown: unit => promise<unit>}

let serve = async (~config: Config.t, ~projectRoot, ~port=?, ~exposeErrors=false) => {
  let relativePath = switch config.resolvers {
  | Some(relativePath) => relativePath
  | None =>
    JsError.throwWithMessage(
      "There is nothing to serve: config.yaml has no `resolvers:` entry. Add one naming the module that declares them, e.g. `resolvers: src/Resolvers.ts`.",
    )
  }
  await loadOrThrow(~projectRoot, ~relativePath)

  // Checked here too, not only at manifest time: `envio dev` never writes the
  // artefacts, and a collision it doesn't catch becomes a schema serve refuses.
  checkCollisions(buildRegisteredManifest().manifest, schemaNamesOf(config))

  let resolvers = getRegisteredResolvers()
  if resolvers->Utils.Array.isEmpty {
    Logging.warn(
      `'${relativePath}' declared no resolvers, so this process will answer nothing. Every resolver has to be created with createResolver at module scope to register.`,
    )
  }

  // Only the Postgres-backed entities: an entity kept elsewhere has no table
  // for a loader to read, and leaving it out is what makes the unknown-entity
  // error name what is actually queryable.
  let entities = Dict.make()
  config->Config.getPgUserEntities->Array.forEach(entity => entities->Dict.set(entity.name, entity))

  let pool = createResolverPoolFromEnv({entities, pgSchema: Env.Db.publicSchema})
  let server = await startResolverServer({resolvers, pool, ?port, exposeErrors})
  Logging.info(
    `Serving ${resolvers
      ->Array.length
      ->Int.toString} custom resolvers on port ${server.port->Int.toString}`,
  )

  let stopped = ref(None)
  let shutdown = () =>
    switch stopped.contents {
    | Some(promise) => promise
    | None =>
      let promise = (
        async () => {
          // In-flight requests finish; the grace period only bounds how long
          // an idle connection can delay the exit.
          switch await Promise.race([server.close(), Utils.delay(closeGracePeriodMs)]) {
          | () => ()
          | exception _ => ()
          }
          switch await pool->endPool {
          | () => ()
          | exception _ => ()
          }
        }
      )()
      stopped := Some(promise)
      promise
    }

  {server, pool, shutdown}
}

/// Wires SIGTERM/SIGINT to `shutdown`, so a rolling update drains rather than
/// severs. Separate from `serve` because a caller embedding it -- a test, or
/// `envio dev` -- owns the process's signals itself.
let handleSignals = (running: running) =>
  ["SIGTERM", "SIGINT"]->Array.forEach(signal =>
    onSignal(signal, () => {
      Logging.info(`Received ${signal}, draining custom resolvers...`)
      let _ = (
        async () => {
          await running.shutdown()
          NodeJs.process->NodeJs.exitWithCode(Success)
        }
      )()
    })
  )
