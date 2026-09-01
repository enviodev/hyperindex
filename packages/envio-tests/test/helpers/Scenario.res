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
  // Feed this chain's items through a wildcard registration rather than an
  // address-dependent one, so its partition takes the wildcard path.
  isWildcard?: bool,
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
  let isUnsupported =
    unsupported->Array.some(({backend}) => backend === IndexerRunner.selectedBackend)

  // A scenario that can't run on ClickHouse doesn't get shaped for it: some
  // schemas the other backends accept (an unbounded BigInt id, say) fail the
  // parse outright once ClickHouse storage is on, which would take the whole
  // file down before the skip could apply.
  let configYaml = switch IndexerRunner.selectedBackend {
  | #clickhouse if !isUnsupported => configYaml->withClickHouseStorage
  | #clickhouse | #postgres => configYaml
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
//
// The runner starts every chain in the config, so a chain left unmocked would
// query the source its YAML names — a live URL. Requiring the two sets to match
// exactly turns that into a failure at setup rather than a hanging test.
let withMockSources = (config: Config.t, ~sources: array<(int, MockSource.t)>) => {
  let configured = config.chainMap->ChainMap.keys
  let mocked = sources->Array.map(((chain, _)) => chain->ChainId.fromInt)

  let missing =
    configured
    ->Array.filter(chainId => !(mocked->Array.some(mock => mock == chainId)))
    ->Array.map(ChainId.toString)
  if missing->Utils.Array.notEmpty {
    JsError.throwWithMessage(
      `Chains ${missing->Array.join(", ")} are configured but have no mock source. Add them to \`~sources\`, or drop them from the scenario's YAML.`,
    )
  }

  let unknown =
    mocked
    ->Array.filter(chainId => !(configured->Array.some(configured => configured == chainId)))
    ->Array.map(ChainId.toString)
  if unknown->Utils.Array.notEmpty {
    JsError.throwWithMessage(
      `Mock sources given for chains ${unknown->Array.join(", ")}, which the scenario's YAML doesn't configure.`,
    )
  }

  // A chain may be given several mocks — a Sync and a Realtime one, say — and
  // they reach its source config in the order `~sources` listed them.
  let chainMap = config.chainMap->ChainMap.mapWithKey((chainId, chainConfig) =>
    switch sources->Array.filter(((mockedChain, _)) => mockedChain->ChainId.fromInt == chainId) {
    | [] => chainConfig
    | mocks => {
        ...chainConfig,
        sourceConfig: Config.CustomSources(mocks->Array.map(((_, mock)) => mock.source)),
      }
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
  body: (~indexer: IndexerRunner.t, ~source: (int, ~index: int=?) => MockSource.t) => promise<unit>,
) => {
  let mocks =
    sources->Array.map(({chain, ?methods, ?sourceFor, ?pollingInterval, ?isWildcard}) => (
      chain,
      MockSource.make(
        methods->Option.getOr(defaultMethods),
        ~chainId=chain,
        ~sourceFor?,
        ~pollingInterval?,
        ~isWildcard?,
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

  // `~index` picks between several mocks given for one chain, in the order
  // `~sources` listed them.
  let source = (chain, ~index=0) =>
    switch mocks
    ->Array.filter(((mockedChain, _)) => mockedChain === chain)
    ->Array.get(index) {
    | Some((_, mock)) => mock
    | None =>
      JsError.throwWithMessage(
        `No mock source at index ${index->Int.toString} for chain ${chain->Int.toString}. Add it to \`~sources\` in Scenario.run.`,
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
    ~onIndexerStopped=() => mocks->Array.forEach(((_, mock)) => mock.dropPendingCalls()),
    async indexer => {
      await body(~indexer, ~source)
      // Only after the body passed: a failing body has its own error to report,
      // and answers it never got to were never going to be claimed anyway.
      mocks->Array.forEach(((_, mock)) => mock.validateAnswersClaimed())
    },
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
  ~timeout=?,
  ~retry=?,
  body: (
    ~t: Vitest.testContext,
    ~indexer: IndexerRunner.t,
    ~source: (int, ~index: int=?) => MockSource.t,
  ) => promise<unit>,
) => {
  switch scenario->skipReason {
  | Some(reason) =>
    Vitest.Async.it_skip(
      `${name} [no ${IndexerRunner.selectedBackend->IndexerRunner.backendName}: ${reason}]`,
      async _ => (),
    )
  | None =>
    let runBody = async (t: Vitest.testContext) =>
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
    switch retry {
    | Some(retry) => Vitest.Async.itWithOptions(name, {retry, timeout: ?timeout}, runBody)
    | None => Vitest.Async.it(name, runBody, ~timeout?)
    }
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
  await Utils.delay(0)
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

// Polls until `predicate` holds. Bounded so a condition that never arrives
// fails with what it was waiting for, rather than as a suite-level timeout.
let waitUntil = async (predicate, ~message, ~timeoutMs=5000.) => {
  let deadline = Date.now() +. timeoutMs
  while !predicate() {
    if Date.now() > deadline {
      JsError.throwWithMessage(`Timed out waiting for ${message}`)
    }
    await Utils.delay(1)
  }
}

// A refused write reaches the indexer's error boundary rather than a promise the
// test could await, so `onError` captures it there. `awaitStorageError` answers
// with what an operator would have been shown: the storage error's own message
// and the reason underneath it.
type refusal = {
  onError: ErrorHandling.t => unit,
  awaitStorageError: unit => promise<option<(string, string)>>,
}

let captureRefusal = () => {
  let captured = ref(None)
  {
    onError: errHandler => captured := Some(errHandler),
    awaitStorageError: async () => {
      // Generous: the refusal crosses a real ClickHouse round trip and the
      // indexer's error boundary, and a slow runner missing it fails as a
      // timeout rather than as the assertion the test is about.
      await waitUntil(
        () => captured.contents->Option.isSome,
        ~message="the write to be refused",
        ~timeoutMs=15000.,
      )
      switch captured.contents {
      | Some({exn: Persistence.StorageError({message, reason})}) =>
        Some((
          message,
          (reason->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"],
        ))
      | _ => None
      }
    },
  }
}
