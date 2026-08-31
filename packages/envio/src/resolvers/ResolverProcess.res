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

type stats
@module("node:fs") external statSync: string => stats = "statSync"
@send external isDirectory: stats => bool = "isDirectory"

type globOptions = {cwd: string}
@module("node:fs/promises")
external globIn: (string, globOptions) => Utils.asyncIterator<string> = "glob"

// `resolvers:` may name a directory as well as a file, because the reference
// implementation keeps its resolvers as `resolvers/<name>/index.ts` -- a
// parent of subdirectories -- and `handlers:` has auto-loaded exactly that
// shape since before this feature existed. Same glob, same exclusions, so the
// two config fields do not need separate explanations.
let sourceFilesIn = async (~absoluteDir, ~relativePath) => {
  let files = try {
    let iterator = globIn("**/*.{js,mjs,ts}", {cwd: absoluteDir})
    await iterator->Utils.Array.fromAsyncIterator
  } catch {
  | exn =>
    JsError.throwWithMessage(
      `Failed to read the resolvers directory '${relativePath}'. Node 22 or newer is required for directory auto-loading. Cause: ${exn
        ->Utils.prettifyExn
        ->Obj.magic}`,
    )
  }
  files
  // Specs live beside the code they cover in the reference layout, and
  // importing one runs `describe` outside a test runner. Same exclusions as
  // `handlers:`, plus declaration files, which have nothing to execute.
  ->Array.filter(file =>
    !(
      file->String.includes(".test.") ||
      file->String.includes(".spec.") ||
      file->String.includes("_test.") ||
      file->String.endsWith(".d.ts")
    )
  )
  // Sorted, so the manifest and the SDL derived from it are the same on every
  // machine rather than following whatever order the filesystem returns.
  ->Array.toSorted(String.compare)
}

let loadOrThrow = async (~projectRoot, ~relativePath) => {
  let absolute = NodeJs.Path.resolve([projectRoot, relativePath])->NodeJs.Path.toString
  // A missing path deliberately falls through to the single-module import, so
  // the error still names the file and says what Node made of it.
  let isDir = switch statSync(absolute) {
  | stats => stats->isDirectory
  | exception _ => false
  }

  let relativePaths = if isDir {
    let files = await sourceFilesIn(~absoluteDir=absolute, ~relativePath)
    if files->Utils.Array.isEmpty {
      Logging.warn(
        `'${relativePath}' is a directory with no .js, .mjs or .ts files in it, so no resolvers were loaded.`,
      )
    }
    // Kept relative, so a load failure names the path the user wrote in
    // config.yaml plus the file under it, not an absolute machine path.
    files->Array.map(file => `${relativePath}/${file}`)
  } else {
    [relativePath]
  }

  for index in 0 to relativePaths->Array.length - 1 {
    let path = relativePaths->Array.getUnsafe(index)
    switch await Utils.importPath(toImportUrl(~projectRoot, ~relativePath=path)) {
    | _ => ()
    | exception exn =>
      // `anyToExnInternal`, not `prettifyExn`: the latter hands back the raw JS
      // error cast to `exn`, so matching `JsExn(_)` on it never fires and every
      // cause reads "unknown error".
      let cause = switch exn->JsExn.anyToExnInternal {
      | JsExn(e) => e->JsExn.message->Option.getOr("no message")
      | _ => "unknown error"
      }
      JsError.throwWithMessage(
        `Failed to load the resolvers module '${path}' named by \`resolvers:\` in config.yaml. Cause: ${cause}`,
      )
    }
  }
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

@module("node:fs") external copyFileSync: (string, string) => unit = "copyFileSync"
@module("node:fs") external existsSync: string => bool = "existsSync"

type spawnOptions = {env: dict<string>, stdio: string, detached: bool, cwd?: string}
type child
@module("node:child_process")
external spawn: (string, array<string>, spawnOptions) => child = "spawn"
@send external unref: child => unit = "unref"
@get external childPid: child => option<int> = "pid"
@send external killChild: (child, string) => bool = "kill"
@send external onChildExit: (child, string, (Nullable.t<int>, Nullable.t<string>) => unit) => unit = "on"
@val external processEnv: dict<string> = "process.env"

@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external pathDirname: string => string = "dirname"

type httpResponse
type fetchInit = {method: string}
@val external fetchUrl: (string, fetchInit) => promise<httpResponse> = "fetch"
@get external responseOk: httpResponse => bool = "ok"

// The resolver process is started by re-invoking this package's own `bin.mjs`,
// resolved from this module rather than from `process.argv` -- dev is not
// always what argv names (a test runner isn't), and `node_modules/.bin/envio`
// is a shim into whichever version is published rather than this one.
let cliEntry = () =>
  NodeJs.Path.resolve([
    pathDirname(fileURLToPath(NodeJs.ImportMeta.url)),
    "..",
    "..",
    "bin.mjs",
  ])->NodeJs.Path.toString

@val @scope("process") external execPath: string = "execPath"

type dbHandle
type sqlFn
type resolverRef = {name: string, timeoutMs: int}
@send external forResolver: (pool, resolverRef) => dbHandle = "forResolver"
@get external sqlOf: dbHandle => sqlFn = "sql"
@send
external unsafe: (sqlFn, string, array<JSON.t>) => promise<array<{"n": int}>> = "unsafe"

type running = {server: server, pool: pool, shutdown: unit => promise<unit>}

let serve = async (~config: Config.t, ~projectRoot, ~port=?, ~exposeErrors=?) => {
  let exposeErrors = exposeErrors->Option.getOr(Env.Resolvers.exposeErrors())
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

// `envio dev` only. `envio start` never calls it — a deployment runs the
// resolvers as their own Deployment.
//
// Dev spawns `envio resolvers` as a child rather than serving in-process, so
// local and hosted run the same command over the same HTTP seam, with a pool
// and a lifetime of their own. It also makes a resolver edit a restart of that
// process alone: the indexer keeps its place, and a resolver that crashes
// takes nothing with it.
//
// Hasura cannot serve custom fields, so the endpoint has to be envio-serve.
// Until it ships as an image, `ENVIO_SERVE_BIN` points at a local build and
// this starts it; without it, everything else still runs and the hint says
// what is missing.
type devResolvers = {port: int, pid: option<int>, stop: unit => promise<unit>}

// Bounded: a resolver module that throws on import never binds the port, and
// waiting forever would leave `envio dev` looking hung rather than saying so.
let healthzTimeoutMs = 20_000

let waitForHealthz = async (~port) => {
  let deadline = Date.now() +. healthzTimeoutMs->Int.toFloat
  let rec attempt = async () => {
    let answered = switch await fetchUrl(
      `http://127.0.0.1:${port->Int.toString}/healthz`,
      {method: "GET"},
    ) {
    | response => response->responseOk
    | exception _ => false
    }
    if answered {
      true
    } else if Date.now() > deadline {
      false
    } else {
      await Utils.delay(200)
      await attempt()
    }
  }
  await attempt()
}

let stopChild = (child): promise<unit> =>
  Promise.make((resolve, _) => {
    switch child->childPid {
    | None => resolve()
    | Some(_) =>
      child->onChildExit("exit", (_, _) => resolve())
      let _ = child->killChild("SIGTERM")
      // SIGTERM runs the child's drain; the race only bounds how long an idle
      // connection can hold the exit up.
      let _ = (
        async () => {
          await Utils.delay(closeGracePeriodMs)
          resolve()
        }
      )()
    }
  })

let startForDev = async (~config: Config.t, ~projectRoot) => {
  switch config.resolvers {
  | None => None
  // Set when you are running `envio resolvers` and envio-serve yourself —
  // under a debugger, or with env of your own.
  | Some(_) if processEnv->Dict.get("ENVIO_RESOLVERS_EXTERNAL") == Some("true") =>
    Logging.info(
      "ENVIO_RESOLVERS_EXTERNAL=true — not starting resolvers here. Run `envio resolvers` in another terminal, and envio-serve against .envio/serve-project.",
    )
    None
  | Some(_) =>
    let configFile = processEnv->Dict.get("ENVIO_CONFIG")->Option.getOr("config.yaml")
    let port = Env.Resolvers.port()

    let childEnv = Dict.copy(processEnv)
    childEnv->Dict.set("ENVIO_RESOLVERS_PORT", port->Int.toString)
    // Locally the caller is the person who wrote the resolver, so an
    // unexpected error's own message is what they need to see.
    childEnv->Dict.set("ENVIO_RESOLVERS_EXPOSE_ERRORS", "true")
    childEnv->Dict.set("ENVIO_CONFIG", configFile)

    let resolverChild = spawn(
      execPath,
      [cliEntry(), "resolvers"],
      {env: childEnv, stdio: "inherit", detached: false, cwd: projectRoot},
    )
    // The indexer owns this process's lifetime; a resolver exiting is reported,
    // never fatal.
    resolverChild->onChildExit("exit", (code, signal) =>
      switch (code->Nullable.toOption, signal->Nullable.toOption) {
      | (Some(0), _) => ()
      | (_, Some(s)) => Logging.info(`Custom resolvers stopped (${s}).`)
      | (Some(c), _) =>
        Logging.error(
          `The custom resolvers process exited with code ${c->Int.toString}. The indexer keeps running; fix the resolver and run \`envio dev\` again.`,
        )
      | _ => Logging.info("Custom resolvers stopped.")
      }
    )

    if !(await waitForHealthz(~port)) {
      Logging.warn(
        `The custom resolvers process did not answer /healthz on port ${port->Int.toString} within ${(healthzTimeoutMs / 1000)
            ->Int.toString}s. Its own output above says why.`,
      )
    }

    let serveDir = NodeJs.Path.resolve([projectRoot, ".envio", "serve-project"])
    await NodeJs.Fs.Promises.mkdir(~path=serveDir, ~options={recursive: true})
    let envioDir = NodeJs.Path.resolve([projectRoot, ".envio"])->NodeJs.Path.toString
    let root = NodeJs.Path.resolve([projectRoot])->NodeJs.Path.toString
    [
      (NodeJs.Path.resolve([root, configFile])->NodeJs.Path.toString, "config.yaml"),
      (NodeJs.Path.resolve([root, "schema.graphql"])->NodeJs.Path.toString, "schema.graphql"),
      (`${envioDir}/resolvers.json`, "resolvers.json"),
    ]->Array.forEach(((from, to_)) =>
      if existsSync(from) {
        copyFileSync(from, `${serveDir->NodeJs.Path.toString}/${to_}`)
      }
    )

    let serveChild = ref(None)
    switch processEnv->Dict.get("ENVIO_SERVE_BIN") {
    | Some(bin) if existsSync(bin) =>
      let servePort = processEnv->Dict.get("ENVIO_SERVE_PORT")->Option.getOr("8080")
      let startServe = () => {
        let serveEnv = Dict.copy(processEnv)
        serveEnv->Dict.set("ENVIO_SERVE_RESOLVERS_URL", `http://127.0.0.1:${port->Int.toString}`)
        let child = spawn(
          bin,
          [
            "--directory",
            serveDir->NodeJs.Path.toString,
            "--config",
            "config.yaml",
            "--port",
            servePort,
          ],
          {env: serveEnv, stdio: "inherit", detached: false},
        )
        child->unref
        serveChild := Some(child)
        Logging.info(`Custom resolvers ready — GraphQL with custom fields on port ${servePort}`)
      }

      // Serve refuses to boot against a database with no tables, and the
      // indexer is what creates them — but the indexer only starts once this
      // function returns. So the wait runs detached: awaiting it here would
      // block the very thing it is waiting for.
      let pool = createResolverPoolFromEnv({
        entities: Dict.make(),
        pgSchema: Env.Db.publicSchema,
      })
      let sql = (pool->forResolver({name: "dev-wait", timeoutMs: 5000}))->sqlOf
      let rec waitForTables = async attempt =>
        if attempt >= 120 {
          Logging.warn("Timed out waiting for the indexer's tables; starting envio-serve anyway.")
          startServe()
          await pool->endPool
        } else {
          let count = switch await sql->unsafe(
            "SELECT count(*)::int AS n FROM information_schema.tables WHERE table_schema = $1;",
            [JSON.Encode.string(Env.Db.publicSchema)],
          ) {
          | rows => rows->Array.get(0)->Option.mapOr(0, row => row["n"])
          | exception _ => 0
          }
          if count > 0 {
            startServe()
            await pool->endPool
          } else {
            await Utils.delay(1000)
            await waitForTables(attempt + 1)
          }
        }
      let _ = waitForTables(0)
    | _ =>
      Logging.warn(
        `Resolvers are declared but ENVIO_SERVE_BIN is not set, so no GraphQL server was started for them. ` ++
        `Hasura cannot serve custom fields. Point ENVIO_SERVE_BIN at an envio-serve binary, or run it yourself against ${serveDir->NodeJs.Path.toString}.`,
      )
    }

    let stop = async () => {
      switch serveChild.contents {
      | Some(child) => await stopChild(child)
      | None => ()
      }
      await stopChild(resolverChild)
    }
    // Ctrl-C reaches the children through the process group, but a bare
    // SIGTERM to `envio dev` does not — without this the resolver process
    // outlives it and the next run cannot bind the port.
    let killChildren = () => {
      switch serveChild.contents {
      | Some(child) => ignore(child->killChild("SIGTERM"))
      | None => ()
      }
      ignore(resolverChild->killChild("SIGTERM"))
    }
    onSignal("exit", killChildren)
    // Registering a signal listener replaces Node's default handler, which is
    // what terminates the process — so having taken the signal, this has to
    // finish the job the default would have done. Nothing else in the indexer
    // handles these.
    ["SIGTERM", "SIGINT"]->Array.forEach(signal =>
      onSignal(signal, () => {
        killChildren()
        NodeJs.process->NodeJs.exitWithCode(Success)
      })
    )

    Some({port, pid: resolverChild->childPid, stop})
  }
}
