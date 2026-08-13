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

// The ClickHouse leg indexes the same scenario with the sink switched on. It's
// a config choice a user makes in YAML, so it's made there rather than by
// patching the parsed config — that way the entities pick up their ClickHouse
// storage flags through the same parse a user's would.
let withClickHouseStorage = configYaml =>
  if configYaml->String.match(%re("/^storage:/m"))->Option.isSome {
    // The scenario configures storage itself; leave its choice alone.
    configYaml
  } else {
    configYaml ++ "\nstorage:\n  postgres:\n    default: true\n  clickhouse:\n    default: true\n"
  }

let make = (~configYaml, ~schema=?, ~env=?, ~files=?, ~handlers=?, ~unsupported=[]): t => {
  let configYaml = switch IndexerRunner.selectedBackend {
  | #clickhouse => configYaml->withClickHouseStorage
  | #memory | #postgres => configYaml
  }

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

// Knobs a user has no say over: they exist to make a scenario reach a state
// that would otherwise need thousands of blocks or addresses. Anything a user
// can configure belongs in the YAML instead.
let withInternalOverrides = (
  config: Config.t,
  ~maxAddrInPartition,
  ~clientFilterAddressThreshold,
  ~reorgThresholdReadyTolerance,
) => {
  ...config,
  maxAddrInPartition: maxAddrInPartition->Option.getOr(config.maxAddrInPartition),
  clientFilterAddressThreshold: clientFilterAddressThreshold->Option.getOr(
    config.clientFilterAddressThreshold,
  ),
  reorgThresholdReadyTolerance: reorgThresholdReadyTolerance->Option.getOr(
    config.reorgThresholdReadyTolerance,
  ),
}

let run = async (
  scenario: t,
  ~sources: array<sourceMock>=[],
  ~reducedPollingInterval=?,
  ~targetBufferSize=?,
  ~maxAddrInPartition=?,
  ~clientFilterAddressThreshold=?,
  ~reorgThresholdReadyTolerance=?,
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

  let config =
    scenario.config
    ->withMockSources(~sources=mocks)
    ->withInternalOverrides(
      ~maxAddrInPartition,
      ~clientFilterAddressThreshold,
      ~reorgThresholdReadyTolerance,
    )

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
  ~maxAddrInPartition=?,
  ~clientFilterAddressThreshold=?,
  ~reorgThresholdReadyTolerance=?,
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
        ~maxAddrInPartition?,
        ~clientFilterAddressThreshold?,
        ~reorgThresholdReadyTolerance?,
        ~onError?,
        ~onExit?,
        ~mapStorage?,
        (~indexer, ~source) => body(~t, ~indexer, ~source),
      )
    )
  }
}

// Drives a chain through the reorg-threshold transition: the first query stops
// `maxReorgDepth` short of the head, and the response commits before the
// post-threshold range opens up. Several scenarios need to be past this point
// before the behaviour they test is reachable.
let enterReorgThreshold = async (
  ~t: Vitest.testContext,
  ~indexer: IndexerRunner.t,
  ~source: MockSource.t,
  ~head=300,
  ~preThresholdTo=100,
  ~fromBlock=1,
) => {
  t.expect(
    source.getHeightOrThrowCalls->Array.length,
    ~message="should have called getHeightOrThrow to get initial height",
  ).toEqual(1)
  source.resolveGetHeightOrThrow(head)
  await Utils.delay(0)
  await Utils.delay(0)

  t.expect(
    source.getItemsOrThrowCalls->Array.map(call => call.payload),
    ~message="Should request items until reorg threshold",
  ).toEqual([{"fromBlock": fromBlock, "toBlock": Some(preThresholdTo), "retry": 0, "p": "0"}])
  source.resolveGetItemsOrThrow([])
  await indexer.getBatchWritePromise()
}
