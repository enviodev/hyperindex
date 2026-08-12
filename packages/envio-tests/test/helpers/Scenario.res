// A scenario is a whole indexer described the way a user describes one — a
// config.yaml, a schema.graphql and handler source — run against the real
// indexer loop with its sources mocked.
//
// Everything the user can configure belongs in the YAML. The arguments `run`
// takes are the knobs a user has no say over: test-only timings and fault
// injection.
//
// Note: `handlers` is a ReScript template string, so a literal `${` in the
// source must be escaped.

type backend = IndexerRunner.backend

// A backend this scenario can't run on, and why. The reason shows up in the
// skip message — an opt-out nobody can explain is an opt-out nobody revisits.
type unsupported = {backend: backend, reason: string}

type t = {
  config: Config.t,
  publicConfigJson: JSON.t,
  // Type-checked at `make`, written to disk per `run`: handlers register as an
  // import side effect, and a module URL only runs its side effects once.
  handlers: option<string>,
  unsupported: array<unsupported>,
  site: string,
}

type sourceMock = {
  chain: int,
  methods?: array<MockSource.method>,
  sourceFor?: Source.sourceFor,
  pollingInterval?: int,
}

let defaultMethods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow]

let make = (~configYaml, ~schema=?, ~env=?, ~files=?, ~handlers=?, ~unsupported=[]): t => {
  let withIndexerTypes = handlers->Option.isSome
  let {config: configJson, indexerTypes} = Core.fromUserApi(
    ~schema?,
    ~env?,
    ~files?,
    ~withIndexerTypes,
    configYaml,
  )

  let site = UserModule.callSite()

  switch handlers {
  | None => ()
  | Some(source) =>
    let typesDts = switch indexerTypes->Null.toOption {
    | Some(typesDts) => typesDts
    | None => JsError.throwWithMessage("Config parsed without generated indexer types.")
    }
    switch UserModule.typeErrors(~typesDts, ~handlers=source) {
    | Some(message) => JsError.throwWithMessage(message)
    | None => ()
    }
  }

  let publicConfigJson = configJson->JSON.parseOrThrow
  {
    config: Config.fromPublic(publicConfigJson),
    publicConfigJson,
    handlers,
    unsupported,
    site,
  }
}

// Swap every mocked chain's source for the test double. The rest of the config
// — chains, contracts, block ranges, reorg settings — is whatever the YAML said.
let withMockSources = (config: Config.t, ~sources: array<(int, MockSource.t)>) => {
  let chainMap = config.chainMap->ChainMap.mapWithKey((chainId, chainConfig) =>
    switch sources->Array.find(((mockedChain, _)) => mockedChain->ChainId.fromInt == chainId) {
    | Some((_, mock)) => {...chainConfig, sourceConfig: Config.CustomSources([mock.source])}
    | None => chainConfig
    }
  )
  {...config, chainMap}
}

let run = async (
  scenario: t,
  ~sources: array<sourceMock>=[],
  ~reducedPollingInterval=?,
  ~targetBufferSize=?,
  ~onError=?,
  ~onExit=?,
  ~mapStorage=?,
  body: (~indexer: IndexerRunner.t, ~source: int => MockSource.t) => promise<unit>,
) => {
  let mocks =
    sources->Array.map(({chain, ?methods, ?sourceFor, ?pollingInterval}) => (
      chain,
      MockSource.make(
        methods->Option.getOr(defaultMethods),
        ~chainId=chain,
        ~sourceFor?,
        ~pollingInterval?,
      ),
    ))

  let config = scenario.config->withMockSources(~sources=mocks)

  let source = chain =>
    switch mocks->Array.find(((mockedChain, _)) => mockedChain === chain) {
    | Some((_, mock)) => mock
    | None =>
      JsError.throwWithMessage(
        `No mock source for chain ${chain->Int.toString}. Add it to \`~sources\` in Scenario.run.`,
      )
    }

  // One registration for the whole run, so a restart reuses the handlers the
  // first pass imported rather than re-importing a module the loader has
  // already cached.
  let registration = HandlerRegister.makeRegistration(~config)
  let imported = ref(false)

  await IndexerRunner.run(
    ~config,
    ~resolveRegistrations=() =>
      registration->HandlerRegister.useRegistration(async () => {
        switch (scenario.handlers, imported.contents) {
        | (Some(source), false) =>
          imported := true
          await UserModule.importModule(
            UserModule.write(~kind="handlers", ~site=scenario.site, ~source),
          )
        | _ => ()
        }
        HandlerRegister.finishRegistration(~config)
      }),
    ~reducedPollingInterval?,
    ~targetBufferSize?,
    ~onError?,
    ~onExit?,
    ~mapStorage?,
    indexer => body(~indexer, ~source),
  )
}

let skipReason = (scenario: t) =>
  scenario.unsupported
  ->Array.find(({backend}) => backend === IndexerRunner.selectedBackend)
  ->Option.map(({reason}) => reason)

// Registers a vitest test that runs `body` against this scenario. A backend the
// scenario declares unsupported is skipped by name and reason, so the reporter
// says which coverage the run is missing instead of quietly passing.
let it = (
  scenario: t,
  name,
  ~sources: array<sourceMock>=[],
  ~reducedPollingInterval=?,
  ~targetBufferSize=?,
  ~onError=?,
  ~onExit=?,
  ~mapStorage=?,
  body: (
    ~t: Vitest.testContext,
    ~indexer: IndexerRunner.t,
    ~source: int => MockSource.t,
  ) => promise<unit>,
) => {
  switch scenario->skipReason {
  | Some(reason) =>
    Vitest.Async.it_skip(
      `${name} [no ${IndexerRunner.selectedBackend->IndexerRunner.backendName}: ${reason}]`,
      async _ => (),
    )
  | None =>
    Vitest.Async.it(name, async t =>
      await scenario->run(
        ~sources,
        ~reducedPollingInterval?,
        ~targetBufferSize?,
        ~onError?,
        ~onExit?,
        ~mapStorage?,
        (~indexer, ~source) => body(~t, ~indexer, ~source),
      )
    )
  }
}
