// Type-checks handler source against a config's generated `indexer` surface.
// Lives in TypeScript (`TypeChecker.ts`) since it drives the TS compiler API.
@module("./TypeChecker.ts")
external checkHandlerTypes: (string, string) => array<string> = "checkHandlerTypes"

type sources = {handlers?: string, test?: string}
@module("./TypeChecker.ts")
external checkSources: (string, sources) => array<string> = "checkSources"

type parsed = {
  config: Config.t,
  publicConfigJson: JSON.t,
}

// Parse the same YAML a user supplies, then cross the public JSON boundary used at runtime.
// When `handlers` (TS source using `import {indexer} from "envio"`) is supplied, the same
// parse also emits the generated types, and the handlers are type-checked against them;
// any type error is thrown.
let fromUserApi = (~schema=?, ~env=?, ~files=?, ~handlers=?, ~configYaml): parsed => {
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
  {
    publicConfigJson,
    config: Config.fromPublic(publicConfigJson),
  }
}

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:crypto") external randomUUID: unit => string = "randomUUID"
@val external importMetaUrl: string = "import.meta.url"

// `describe` with a callback vitest awaits during collection, so tests
// registered by a module imported inside it land in this suite.
@module("vitest")
external describeAsync: (string, unit => promise<unit>) => promise<unit> = "describe"

// Emitted here rather than in envio so vite-node transforms the generated
// module and its bare `envio` import resolves to the instance already loaded.
let importModule: string => promise<unit> = %raw(`(path) => import(path)`)

// `file:line` of the `defineIndexerTest` call — the first stack frame outside
// this helper — so a failing suite names the fixture that produced it.
let callSite: unit => string = %raw(`() => {
  const stack = new Error().stack ?? "";
  for (const frame of stack.split("\n").slice(1)) {
    const match = frame.match(/\(?([^()\s]+):(\d+):(\d+)\)?\s*$/);
    if (!match) continue;
    const file = match[1];
    if (file.startsWith("node:") || file.includes("InternalTestIndexer")) continue;
    return file.split(/[\\/]/).pop() + ":" + match[2];
  }
  return "unknown";
}`)

let tmpDir = pathJoin([pathDirname(fileURLToPath(importMetaUrl)), "..", ".tmp"])

// Kept after import: vitest renders code frames from these paths when a test
// fails, so they must outlive the run. `globalSetup.ts` clears the directory
// before any worker starts.
let writeModule = (~kind, ~site, ~source) => {
  let slug = site->String.replaceRegExp(%re("/[^a-zA-Z0-9]+/g"), "-")
  let file = pathJoin([tmpDir, `${slug}-${kind}-${randomUUID()->String.slice(~start=0, ~end=8)}.ts`])
  writeFileSync(file, source)
  file
}

type fixture = {
  // Suite name; defaults to the `defineIndexerTest` call site.
  name?: string,
  configYaml: string,
  schema?: string,
  // Handler module source, exactly as a user's `src/handlers/*.ts`.
  handlers: string,
  // Test module source, exactly as a user's `src/indexer.test.ts`.
  test: string,
}

// Config priming and the handler registry are process-global, so one fixture
// owns the process. Under `pool: "forks"` that means one fixture per file.
let definedAt: ref<option<string>> = ref(None)

// Run a user-facing test module against a config parsed from YAML, with no
// codegen'd project on disk. Both sources are type-checked against the config's
// generated types and then evaluated: handlers register through the normal
// global registry, and the test module's `it()` calls register into the calling
// file's suite, so they get real vitest names, code frames and diffs.
//
// Must be called with top-level `await` from a `.test.ts` file — the imported
// tests only register while the caller is being collected.
let defineIndexerTest = async (fixture: fixture) => {
  let site = callSite()
  let name = switch fixture.name {
  | Some(name) => name
  | None => `indexerTest(${site})`
  }

  let result = try {
    switch definedAt.contents {
    | Some(previous) =>
      JsError.throwWithMessage(
        `defineIndexerTest was already called at ${previous}. The parsed config and handler registry are process-global, so each fixture needs its own test file.`,
      )
    | None => ()
    }
    definedAt := Some(site)

    let {config: configJson, indexerTypes} =
      Core.fromUserApi(~schema=?fixture.schema, ~withIndexerTypes=true, fixture.configYaml)
    let typesDts = switch indexerTypes->Null.toOption {
    | Some(typesDts) => typesDts
    | None => JsError.throwWithMessage("Config parsed without generated indexer types.")
    }

    switch checkSources(typesDts, {handlers: fixture.handlers, test: fixture.test}) {
    | [] => ()
    | errors => JsError.throwWithMessage("Type errors:\n" ++ errors->Array.join("\n"))
    }

    let publicConfigJson = configJson->JSON.parseOrThrow
    // Makes `Config.load()` resolve to this fixture, which is what lets the real
    // `createTestIndexer` from "envio" run with no project on disk.
    Config.prime(publicConfigJson)
    HandlerRegister.startRegistration(~config=Config.fromPublic(publicConfigJson))

    mkdirSync(tmpDir, {"recursive": true})
    await importModule(writeModule(~kind="handlers", ~site, ~source=fixture.handlers))

    let testFile = writeModule(~kind="test", ~site, ~source=fixture.test)
    await describeAsync(name, () => importModule(testFile))
    Ok()
  } catch {
  | exn => Error(exn)
  }

  switch result {
  | Ok() => ()
  // Surface setup failures as a named test rather than a collection crash, so
  // the reporter attributes them to this fixture.
  | Error(exn) => Vitest.it(`${name} setup`, _ => throw(exn))
  }
}
