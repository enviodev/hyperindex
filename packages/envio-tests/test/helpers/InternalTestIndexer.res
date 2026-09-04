// Type-checks user source against a config's generated `indexer` surface.
// Lives in TypeScript (`TypeChecker.ts`) since it drives the TS compiler API.
type sources = {handlers?: string, test?: string}
@module("./TypeChecker.ts")
external checkSources: (string, sources) => array<string> = "checkSources"

// Member names an editor offers at the `/*HERE*/` marker of `handlers`.
@module("./TypeChecker.ts")
external completionsAtUnsafe: (string, string) => array<string> = "completionsAt"

type parsed = {
  config: Config.t,
  // The per-chain registrations the `handlers` module produced, with
  // `~registerHandlers`. Readable from a test body: the module is imported while
  // vitest collects the suite, so nothing at module scope can see them yet.
  registrations: unit => HandlerRegister.registrationsByChainId,
}

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:crypto") external randomUUID: unit => string = "randomUUID"
@val external importMetaUrl: string = "import.meta.url"

// Vitest awaits a suite's callback while building the suite tree, so tests
// registered by a module imported inside it land in this suite — without the
// caller having to await anything. That is what keeps `fromUserApi` synchronous
// and lets fixtures be ordinary `_test.res` files.
@module("vitest")
external describeAsync: (string, unit => promise<unit>) => unit = "describe"

// Emitted here rather than in envio so vite-node transforms the generated
// module and its bare `envio` import resolves to the instance already loaded.
let importModule: string => promise<unit> = %raw(`(path) => import(path)`)

// `file:line` of the `fromUserApi` call — the first stack frame outside this
// helper — so a failing suite names the fixture that produced it.
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

// Config priming and the handler registry are process-global, so a fixture that
// runs tests owns the process. Under `pool: "forks"` that means one such fixture
// per test file; parse-only calls are unrestricted.
let ranTestAt: ref<option<string>> = ref(None)

let claimProcess = (~site) => {
  switch ranTestAt.contents {
  | Some(previous) =>
    JsError.throwWithMessage(
      `fromUserApi already ran a test module at ${previous}. The parsed config and handler registry are process-global, so each one needs its own test file.`,
    )
  | None => ()
  }
  ranTestAt := Some(site)
}

let completionsAt = (~schema=?, ~env=?, ~files=?, ~handlers, ~configYaml): array<string> => {
  let {indexerTypes} = Core.fromUserApi(~schema?, ~env?, ~files?, ~withIndexerTypes=true, configYaml)
  switch indexerTypes->Null.toOption {
  | Some(typesDts) => completionsAtUnsafe(typesDts, handlers)
  | None => JsError.throwWithMessage("Config parsed without generated indexer types.")
  }
}

// Parse the same YAML a user supplies, then cross the public JSON boundary used
// at runtime. `handlers` and `test` are ordinary user modules — the same source
// a project puts in `src/handlers/*.ts` and `src/indexer.test.ts` — type-checked
// against the config's generated types, and with `test`, evaluated: priming the
// config is what lets the real `createTestIndexer` from "envio" run with no
// project on disk.
//
// Note: `test`/`handlers` are ReScript template strings, so a literal `${` in
// the source must be escaped.
let fromUserApi = (
  ~schema=?,
  ~env=?,
  ~files=?,
  ~handlers=?,
  ~test=?,
  // Run the `handlers` module, so `indexer.onEvent` registers for real, and
  // expose what it registered as `parsed.registrations`. Without it a
  // `handlers` source is only type-checked.
  ~registerHandlers=false,
  ~configYaml,
): parsed => {
  let withIndexerTypes = handlers->Option.isSome || test->Option.isSome
  let {config: configJson, indexerTypes} =
    Core.fromUserApi(~schema?, ~env?, ~files?, ~withIndexerTypes, configYaml)

  let typeErrors = if withIndexerTypes {
    let typesDts = switch indexerTypes->Null.toOption {
    | Some(typesDts) => typesDts
    | None => JsError.throwWithMessage("Config parsed without generated indexer types.")
    }
    switch checkSources(typesDts, {handlers: ?handlers, test: ?test}) {
    | [] => None
    | errors => Some("Type errors:\n" ++ errors->Array.join("\n"))
    }
  } else {
    None
  }

  let publicConfigJson = configJson->JSON.parseOrThrow
  let config = Config.fromPublic(publicConfigJson)

  let registrationsRef = ref(None)
  let registrations = () =>
    switch registrationsRef.contents {
    | Some(registrations) => registrations
    | None =>
      JsError.throwWithMessage(
        registerHandlers
          ? "The handlers module hasn't been imported yet. `registrations` is only readable from a test body."
          : "fromUserApi was called without ~registerHandlers, so no handlers were registered.",
      )
    }

  if registerHandlers && handlers->Option.isNone {
    JsError.throwWithMessage("fromUserApi was called with ~registerHandlers but no ~handlers source.")
  }

  switch (test, registerHandlers ? handlers : None) {
  // Parse-only: type errors are thrown at the call site, as callers assert.
  | (None, None) =>
    switch typeErrors {
    | Some(message) => JsError.throwWithMessage(message)
    | None => ()
    }
  // Registration-only: run the handlers module the way a project does, without
  // a test module of its own.
  | (None, Some(handlers)) =>
    switch typeErrors {
    | Some(message) => JsError.throwWithMessage(message)
    | None => ()
    }
    let site = callSite()
    claimProcess(~site)
    HandlerRegister.resetOnEventRegistrations()
    HandlerRegister.startRegistration(~config)
    mkdirSync(tmpDir, {"recursive": true})
    let handlersFile = writeModule(~kind="handlers", ~site, ~source=handlers)
    let collected = ref(false)
    describeAsync(`indexerHandlers(${site})`, async () => {
      await importModule(handlersFile)
      registrationsRef := Some(HandlerRegister.finishRegistration(~config))
      collected := true
    })
    Vitest.it(
      `indexerHandlers(${site}) collected`,
      t =>
        t.expect(
          collected.contents,
          ~message="handlers module was not imported during collection",
        ).toBe(true),
    )
  | (Some(test), _) =>
    let site = callSite()
    let suiteName = `indexerTest(${site})`
    let setup = try {
      switch typeErrors {
      | Some(message) => JsError.throwWithMessage(message)
      | None => ()
      }
      claimProcess(~site)

      // Makes `Config.load()` resolve to this fixture, which is what lets the
      // real `createTestIndexer` from "envio" run with no project on disk.
      Config.prime(publicConfigJson)
      HandlerRegister.startRegistration(~config)

      mkdirSync(tmpDir, {"recursive": true})
      Ok((
        handlers->Option.map(source => writeModule(~kind="handlers", ~site, ~source)),
        writeModule(~kind="test", ~site, ~source=test),
      ))
    } catch {
    | exn => Error(exn)
    }

    switch setup {
    | Ok((handlersFile, testFile)) =>
      let collected = ref(false)
      describeAsync(suiteName, async () => {
        // Handlers must finish registering before the test module's bodies run.
        switch handlersFile {
        | Some(file) => await importModule(file)
        | None => ()
        }
        await importModule(testFile)
        collected := true
      })
      // Registering the tests depends on vitest awaiting the suite callback
      // while collecting. If that ever stops holding, the imported `it()`s
      // simply never register — the suite shrinks instead of failing, which no
      // reporter flags. This sentinel is registered outside the callback, so it
      // still runs and turns that silence into a failure.
      Vitest.it(
        `${suiteName} collected`,
        t => t.expect(collected.contents, ~message="test module was not imported during collection").toBe(true),
      )
    // Surface setup failures as a named test rather than a collection crash, so
    // the reporter attributes them to this fixture.
    | Error(exn) => Vitest.it(`${suiteName} setup`, _ => throw(exn))
    }
  }

  {config, registrations}
}

// The message a config the parser should reject failed with. Returns a
// description of what was expected instead of throwing, so the assertion reads
// as one comparison.
let parseError = (~schema=?, ~env=?, ~files=?, ~configYaml) =>
  try {
    fromUserApi(~schema?, ~env?, ~files?, ~configYaml)->ignore
    "the parse to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }
