// Type-checks handler source against a config's generated `indexer` surface.
// Lives in TypeScript (`TypeChecker.ts`) since it drives the TS compiler API.
@module("./TypeChecker.ts")
external checkHandlerTypes: (string, string) => array<string> = "checkHandlerTypes"

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:fs") external rmSync: (string, {..}) => unit = "rmSync"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@val external importMetaUrl: string = "import.meta.url"
@val external processPid: int = "process.pid"

// The dynamic import must be emitted into this module (compiled under `test/`),
// so vite-node transforms the `.ts` temp file and resolves its bare `envio`
// import to the same externalized copy the tests use. Going through envio's own
// `importPath` would run under native ESM, where importing a `.ts` file fails.
let importPath: string => promise<unit> = %raw(`(p) => import(p)`)

let tmpDir = pathJoin([pathDirname(fileURLToPath(importMetaUrl)), "..", ".tmp"])

// pid keeps names distinct across forked workers; the counter across calls in a
// worker. A fresh name every call defeats the ESM module cache, so each
// `createTestIndexer` re-evaluates the handlers (mirroring the real indexer
// registering once per process).
let tmpCounter = ref(0)

type parsed<'processConfig> = {
  config: Config.t,
  publicConfigJson: JSON.t,
  // Runs the handler source in an isolated registration scope and returns an
  // in-memory test indexer over this config. Requires `~handlers`.
  createTestIndexer: unit => promise<TestIndexer.t<'processConfig>>,
}

// Parse the same YAML a user supplies, then cross the public JSON boundary used at runtime.
// When `handlers` (TS source using `import {indexer} from "envio"`) is supplied, the same
// parse also emits the generated types, and the handlers are type-checked against them;
// any type error is thrown.
let fromUserApi = (~schema=?, ~env=?, ~files=?, ~handlers=?, ~configYaml): parsed<'processConfig> => {
  let {config: configJson, indexerTypes} =
    Core.fromUserApi(~schema?, ~env?, ~files?, ~withIndexerTypes=handlers->Option.isSome, configYaml)

  switch (handlers, indexerTypes->Null.toOption) {
  | (Some(handlers), Some(typesDts)) =>
    switch checkHandlerTypes(typesDts, handlers) {
    | [] => ()
    | errors => JsError.throwWithMessage("Handler type errors:\n" ++ errors->Array.join("\n"))
    }
  | _ => ()
  }

  let publicConfigJson = configJson->JSON.parseOrThrow
  let config = Config.fromPublic(publicConfigJson)

  let createTestIndexer = async () => {
    let handlersSource = switch handlers {
    | Some(source) => source
    | None =>
      JsError.throwWithMessage(
        "createTestIndexer requires `~handlers` source to be passed to fromUserApi.",
      )
    }

    // A queued pre-registration means a handler registered with no scope active
    // (it would silently never run). Surface it instead of proceeding.
    if HandlerRegister.hasPreRegistered() {
      JsError.throwWithMessage(
        "A handler registered outside a test indexer scope. Register handlers synchronously at the top level of the `handlers` source.",
      )
    }

    mkdirSync(tmpDir, {"recursive": true})
    tmpCounter := tmpCounter.contents + 1
    let tmpFile = pathJoin([
      tmpDir,
      `handlers-${processPid->Int.toString}-${tmpCounter.contents->Int.toString}.ts`,
    ])
    writeFileSync(tmpFile, handlersSource)
    let cleanup = () =>
      try rmSync(tmpFile, {"force": true}) catch {
      | _ => ()
      }

    let registration = HandlerRegister.make(~config)
    switch await HandlerRegister.withScope(registration, () => importPath(tmpFile))
    ->Promise.thenResolve(() => Ok())
    ->Promise.catch(exn => Promise.resolve(Error(exn))) {
    | Error(exn) =>
      cleanup()
      throw(exn)
    | Ok() =>
      cleanup()
      if HandlerRegister.hasPreRegistered() {
        JsError.throwWithMessage(
          "A handler registered outside the test indexer scope (registered asynchronously). Register handlers synchronously at the top level of the `handlers` source.",
        )
      }
      let registrations = HandlerRegister.finish(registration, ~config)
      TestIndexer.make(
        ~config,
        ~getRegistrations=() => Promise.resolve(registrations),
        ~getActiveRegistration=() => registration,
        ~envioInfo=Some(publicConfigJson->Config.stripSensitiveData),
      )
    }
  }

  {
    publicConfigJson,
    config,
    createTestIndexer,
  }
}
