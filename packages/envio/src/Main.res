type chainData = {
  chainId: float,
  poweredByHyperSync: bool,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Date.t>,
  numEventsProcessed: float,
  latestFetchedBlockNumber: int,
  // Need this for API backwards compatibility
  @as("currentBlockHeight")
  knownHeight: int,
  numBatchesFetched: int,
  startBlock: int,
  endBlock: option<int>,
  numAddresses: int,
}
@tag("status")
type state =
  | @as("disabled") Disabled({})
  | @as("initializing") Initializing({})
  | @as("active")
  Active({
      envioVersion: string,
      chains: array<chainData>,
      indexerStartTime: Date.t,
      isPreRegisteringDynamicContracts: bool,
      isUnorderedMultichainMode: bool,
      rollbackOnReorg: bool,
    })

let chainDataSchema = S.schema((s): chainData => {
  chainId: s.matches(S.float),
  poweredByHyperSync: s.matches(S.bool),
  firstEventBlockNumber: s.matches(S.option(S.int)),
  latestProcessedBlock: s.matches(S.option(S.int)),
  timestampCaughtUpToHeadOrEndblock: s.matches(S.option(S.datetime(S.string))),
  numEventsProcessed: s.matches(S.float),
  latestFetchedBlockNumber: s.matches(S.int),
  knownHeight: s.matches(S.int),
  numBatchesFetched: s.matches(S.int),
  startBlock: s.matches(S.int),
  endBlock: s.matches(S.option(S.int)),
  numAddresses: s.matches(S.int),
})
let stateSchema = S.union([
  S.literal(Disabled({})),
  S.literal(Initializing({})),
  S.schema(s => Active({
    envioVersion: s.matches(S.string),
    chains: s.matches(S.array(chainDataSchema)),
    indexerStartTime: s.matches(S.datetime(S.string)),
    // Keep the field, since Dev Console expects it to be present
    isPreRegisteringDynamicContracts: false,
    isUnorderedMultichainMode: s.matches(S.bool),
    rollbackOnReorg: s.matches(S.bool),
  })),
])

// Shape of the user-returned `{_gte?, _lte?, _every?}` filter chunk after
// the ecosystem-specific wrapper is stripped. Shared across all ecosystems —
// the outer `block.number` / `block.height` / `slot` unwrap lives on each
// ecosystem's `onBlockFilterSchema`, and the inner range fields are the
// same everywhere.
type blockRange = {
  _gte: option<int>,
  _lte: option<int>,
  _every: int,
}

// `S.strict` rejects unknown fields so typos like `_gt` / `_evry` surface
// with a readable schema error pointing at the offending key, instead of
// silently registering a broken filter. `_every` defaults to 1 inside the
// schema so the caller always sees a plain `int`, and `intMin(1)` rejects
// zero/negative strides — `(blockNumber - startBlock) % 0` would crash and
// any negative stride would never match.
let blockRangeSchema: S.t<blockRange> = S.object(s => {
  _gte: s.field("_gte", S.option(S.int)),
  _lte: s.field("_lte", S.option(S.int)),
  _every: s.field("_every", S.option(S.int->S.intMin(1))->S.Option.getOr(1)),
})->S.strict

let defaultBlockRange: blockRange = {_gte: None, _lte: None, _every: 1}

let globalGsManagerRef: ref<option<GlobalStateManager.t>> = ref(None)

// Persistence is set by Main.start before handler modules load, so that
// the exported indexer value can lazily expose DB state (startBlock,
// endBlock, isLive, dynamic contract addresses) once it's ready.
let globalPersistenceRef: ref<option<Persistence.t>> = ref(None)

let getInitialChainState = (~chainId: int): option<Persistence.initialChainState> => {
  switch globalPersistenceRef.contents {
  | Some(persistence) =>
    switch persistence.storageStatus {
    | Ready(initialState) => initialState.chains->Array.find(c => c.id === chainId)
    | _ => None
    }
  | None => None
  }
}

// Build the chains object from config. Extracted so the exported indexer
// value can call this lazily (on first `indexer.chains` access) rather than
// eagerly at module load — importing `generated` must not trigger Config.loadWithoutRegistrations().
let buildChainsObject = (~config: Config.t) => {
  let chainIds = []
  let chains = Utils.Object.createNullObject()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    let chainIdStr = chainConfig.id->Int.toString

    chainIds->Array.push(chainConfig.id)->ignore

    let chainObj = Utils.Object.createNullObject()
    chainObj
    ->Utils.Object.definePropertyWithValue("id", {enumerable: true, value: chainConfig.id})
    ->Utils.Object.defineProperty(
      "startBlock",
      {
        enumerable: true,
        get: () => {
          switch getInitialChainState(~chainId=chainConfig.id) {
          | Some(chainState) => chainState.startBlock
          | None => chainConfig.startBlock
          }
        },
      },
    )
    ->Utils.Object.defineProperty(
      "endBlock",
      {
        enumerable: true,
        get: () => {
          // Persistence may store endBlock=None (eg the test indexer's
          // auto-exit mode where the user didn't specify an endBlock).
          // Only override the config when persistence has an explicit value.
          switch getInitialChainState(~chainId=chainConfig.id) {
          | Some({endBlock: Some(_) as eb}) => eb
          | _ => chainConfig.endBlock
          }
        },
      },
    )
    ->Utils.Object.definePropertyWithValue("name", {enumerable: true, value: chainConfig.name})
    ->Utils.Object.defineProperty(
      "isLive",
      {
        enumerable: true,
        get: () => {
          switch globalGsManagerRef.contents {
          | Some(gsManager) =>
            let state = gsManager->GlobalStateManager.getState
            let chain = ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)
            let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
            chainFetcher->ChainFetcher.isReady
          // Before the GlobalStateManager is available (eg during handler
          // module load after resume), derive liveness from persistence:
          // a chain is considered live when it previously caught up to head
          // or endBlock (timestampCaughtUpToHeadOrEndblock is set).
          | None =>
            switch getInitialChainState(~chainId=chainConfig.id) {
            | Some(chainState) => chainState.timestampCaughtUpToHeadOrEndblock->Option.isSome
            | None => false
            }
          }
        },
      },
    )
    ->ignore

    // Add contracts to chain object
    chainConfig.contracts->Array.forEach(contract => {
      let contractObj = Utils.Object.createNullObject()
      contractObj
      ->Utils.Object.definePropertyWithValue("name", {enumerable: true, value: contract.name})
      ->Utils.Object.definePropertyWithValue("abi", {enumerable: true, value: contract.abi})
      ->Utils.Object.defineProperty(
        "addresses",
        {
          enumerable: true,
          get: () => {
            switch globalGsManagerRef.contents {
            | Some(gsManager) => {
                let state = gsManager->GlobalStateManager.getState
                let chain = ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)
                let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
                let indexingAddresses = chainFetcher.fetchState.indexingAddresses

                // Collect all addresses for this contract name from indexingAddresses
                let addresses = []
                let values = indexingAddresses->Dict.valuesToArray
                for idx in 0 to values->Array.length - 1 {
                  let indexingContract = values->Array.getUnsafe(idx)
                  if indexingContract.contractName === contract.name {
                    addresses->Array.push(indexingContract.address)->ignore
                  }
                }
                addresses
              }
            // Before the GlobalStateManager is available (eg during handler
            // module load after resume), combine static addresses from config
            // with dynamic contracts persisted in the database.
            | None =>
              switch getInitialChainState(~chainId=chainConfig.id) {
              | Some(chainState) =>
                let addresses = contract.addresses->Array.copy
                chainState.indexingAddresses->Array.forEach(
                  dc => {
                    if dc.contractName === contract.name {
                      addresses->Array.push(dc.address)->ignore
                    }
                  },
                )
                addresses
              | None => contract.addresses
              }
            }
          },
        },
      )
      ->ignore

      chainObj
      ->Utils.Object.definePropertyWithValue(contract.name, {enumerable: true, value: contractObj})
      ->ignore
    })

    // Primary key is chain ID as string
    chains
    ->Utils.Object.definePropertyWithValue(chainIdStr, {enumerable: true, value: chainObj})
    ->ignore

    // If chain has a name different from ID, add non-enumerable alias
    if chainConfig.name !== chainIdStr {
      chains
      ->Utils.Object.definePropertyWithValue(chainConfig.name, {enumerable: false, value: chainObj})
      ->ignore
    }
  })
  (chains, chainIds)
}

let getGlobalIndexer = (): 'indexer => {
  // Parse eventIdentity config to extract contractName, eventName, and options.
  // Supports two runtime formats:
  // - From TypeScript: { contract: "X", event: "Y", wildcard?, where? }
  // - From ReScript GADT: { event: { contract: "X", _0: "Y" }, wildcard?, where? }
  let parseIdentityConfig = (identityConfig: 'a) => {
    let raw =
      identityConfig->(
        Utils.magic: 'a => {
          "contract": unknown,
          "event": unknown,
          "wildcard": option<bool>,
          "where": option<JSON.t>,
        }
      )
    // Detect format: if "contract" is a string, it's the TS format
    let (contractName, eventName) = if typeof(raw["contract"]) === #string {
      // TS format: { contract: "X", event: "Y" }
      (
        raw["contract"]->(Utils.magic: unknown => string),
        raw["event"]->(Utils.magic: unknown => string),
      )
    } else {
      // ReScript GADT format: { event: { contract: "X", _0: "Y" } }
      let event = raw["event"]->(Utils.magic: unknown => {"contract": string, "_0": string})
      (event["contract"], event["_0"])
    }
    let wildcard = raw["wildcard"]
    let where = raw["where"]
    let eventOptions: option<Internal.eventOptions<_>> = switch (wildcard, where) {
    | (None, None) => None
    | (wildcard, where) =>
      Some({
        ?wildcard,
        where: ?(where->(Utils.magic: option<JSON.t> => option<_>)),
      })
    }
    (contractName, eventName, eventOptions)
  }

  // onEvent: delegates to HandlerRegister.setHandler
  let onEventFn = (identityConfig: 'a, handler: 'b) => {
    HandlerRegister.throwIfFinishedRegistration(~methodName="onEvent")
    let (contractName, eventName, eventOptions) = parseIdentityConfig(identityConfig)
    HandlerRegister.setHandler(
      ~contractName,
      ~eventName,
      handler->(
        Utils.magic: 'b => Internal.genericHandler<
          Internal.genericHandlerArgs<Internal.event, Internal.handlerContext>,
        >
      ),
      ~eventOptions,
    )
  }

  // contractRegister: delegates to HandlerRegister.setContractRegister
  let contractRegisterFn = (identityConfig: 'a, handler: 'b) => {
    HandlerRegister.throwIfFinishedRegistration(~methodName="contractRegister")
    let (contractName, eventName, eventOptions) = parseIdentityConfig(identityConfig)
    HandlerRegister.setContractRegister(
      ~contractName,
      ~eventName,
      handler->(
        Utils.magic: 'b => Internal.genericContractRegister<
          Internal.genericContractRegisterArgs<Internal.event, Internal.contractRegisterContext>,
        >
      ),
      ~eventOptions,
    )
  }

  // Two-stage parse: first the ecosystem-specific outer schema unwraps the
  // wrapper (`block.number` / `block.height` / `slot`) and surfaces the
  // inner chunk as raw `unknown`; then the shared `blockRangeSchema`
  // validates the `{_gte?, _lte?, _every?}` fields. Keeping the inner
  // validation in one place means typos and shape mismatches surface with
  // the same user-friendly error regardless of ecosystem.
  let extractRange = (filter: unknown, ~name, ~ecosystem: Ecosystem.t): blockRange =>
    try {
      switch filter->S.parseOrThrow(ecosystem.onBlockFilterSchema) {
      | None => defaultBlockRange
      | Some(inner) => inner->S.parseOrThrow(blockRangeSchema)
      }
    } catch {
    | S.Raised(exn) =>
      JsError.throwWithMessage(
        `\`indexer.${ecosystem.onBlockMethodName}("${name}")\` \`where\` returned an invalid filter: ${exn
          ->Utils.prettifyExn
          ->(Utils.magic: exn => string)}`,
      )
    }

  // `where` is evaluated once per configured chain at registration time.
  // Decoded ranges/stride feed directly into `HandlerRegister.registerOnBlock`
  // so the fetcher's `(blockNumber - handlerStartBlock) % interval === 0`
  // math at `FetchState.res:619` stays untouched.
  let onBlockFn = (rawOptions: 'a, handler: 'b) => {
    HandlerRegister.throwIfFinishedRegistration(~methodName="onBlock")
    let config = Config.loadWithoutRegistrations()
    let ecosystem = config.ecosystem
    let raw =
      rawOptions->(
        Utils.magic: 'a => {
          "name": string,
          "where": option<Envio.onBlockWhereArgs<unknown> => unknown>,
        }
      )
    let typedHandler = handler->(Utils.magic: 'b => Internal.onBlockArgs => promise<unit>)
    let (chains, _) = buildChainsObject(~config)
    let chainsDict = chains->(Utils.magic: {..} => dict<unknown>)
    let name = raw["name"]
    let logger = Logging.createChild(~params={"onBlock": name})

    // `where` must be a function (unlike onEvent, which also accepts a static
    // value). A static value would have to be evaluated against every chain
    // independently, which has no useful semantic for block handlers.
    // Normalize undefined/null to None up front so the per-chain loop below
    // can't accidentally call `null` as a predicate (ReScript treats a JS
    // `null` value as `Some(null)` when the field is typed as option).
    let where = switch raw["where"]->(Utils.magic: option<'a> => unknown) {
    | w if w === %raw(`undefined`) || w === %raw(`null`) => None
    | w if typeof(w) === #function => Some(raw["where"]->Option.getUnsafe)
    | w =>
      JsError.throwWithMessage(
        `\`indexer.${ecosystem.onBlockMethodName}("${name}")\` expected \`where\` to be a function or omitted, but got ${(typeof(
            w,
          ) :> string)}.`,
      )
    }

    let matchedAny = ref(false)

    config.chainMap
    ->ChainMap.values
    ->Array.forEach(chainConfig => {
      let chainId = chainConfig.id
      let chainObj = chainsDict->Dict.getUnsafe(chainId->Int.toString)

      // Predicate returns `true` → match with no filter; `false` → skip;
      // any plain object → structured filter. `undefined`/`null` returns
      // are rejected — the TS type excludes `void`, so a missing return is
      // a user bug we surface early rather than silently match-all.
      let result = switch where {
      | None => %raw(`true`)
      | Some(predicate) => predicate({chain: chainObj})
      }

      let (shouldRegister, range) = if result === %raw(`true`) {
        (true, defaultBlockRange)
      } else if result === %raw(`false`) {
        (false, defaultBlockRange)
      } else if typeof(result) === #object && !(result->Array.isArray) && result !== %raw(`null`) {
        (true, extractRange(result, ~name, ~ecosystem))
      } else {
        // Reject numbers, strings, functions, arrays, undefined, null —
        // anything that isn't bool or a plain object would silently
        // misregister.
        JsError.throwWithMessage(
          `\`indexer.${ecosystem.onBlockMethodName}("${name}")\` \`where\` predicate returned an invalid value of type ${(typeof(
              result,
            ) :> string)}. Expected boolean or a filter object.`,
        )
      }

      if shouldRegister {
        matchedAny := true
        HandlerRegister.registerOnBlock(
          ~name,
          ~chainId,
          ~interval=range._every,
          ~startBlock=range._gte,
          ~endBlock=range._lte,
          ~handler=typedHandler,
        )
      }
    })

    // Catches misconfigured `where` predicates that return `false` for every
    // configured chain — the handler would otherwise never fire with no hint.
    // Includes the ecosystem-specific method name so SVM users see "onSlot"
    // and don't get confused looking for a "Block handler" they never wrote.
    if !matchedAny.contents {
      logger->Logging.childWarn(
        `\`indexer.${ecosystem.onBlockMethodName}\` matched 0 chains. Check the \`where\` predicate.`,
      )
    }
  }

  // Ecosystem-specific surface: EVM/Fuel expose event + block handlers; SVM
  // exposes slot handlers only. The TS `.d.ts` already models this separation
  // — the Proxy mirrors it at runtime so `Object.keys(indexer)` reflects the
  // actually-callable methods and typos surface via the unknown-prop throw
  // rather than silent `undefined` returns.
  let ecosystem = Config.loadWithoutRegistrations().ecosystem
  let keys = switch ecosystem.name {
  | Evm | Fuel => [
      "name",
      "description",
      "chainIds",
      "chains",
      "onEvent",
      "contractRegister",
      "onBlock",
    ]
  | Svm => ["name", "description", "chainIds", "chains", "onSlot"]
  }

  let get = (~prop: string) =>
    switch prop {
    | "name" => Config.loadWithoutRegistrations().name->(Utils.magic: string => unknown)
    | "description" =>
      Config.loadWithoutRegistrations().description->(Utils.magic: option<string> => unknown)
    | "chainIds" => {
        let (_, chainIds) = buildChainsObject(~config=Config.loadWithoutRegistrations())
        chainIds->(Utils.magic: array<int> => unknown)
      }
    | "chains" => {
        let (chains, _) = buildChainsObject(~config=Config.loadWithoutRegistrations())
        chains->(Utils.magic: {..} => unknown)
      }
    | "onEvent" => onEventFn->Utils.magic
    | "contractRegister" => contractRegisterFn->Utils.magic
    | "onBlock" | "onSlot" => onBlockFn->Utils.magic
    | _ =>
      JsError.throwWithMessage(
        `Field \`${prop}\` does not exist on \`indexer\`. Available fields: ${keys->Array.join(
            ", ",
          )}.`,
      )
    }

  let traps: Utils.Proxy.traps<{..}> = {
    // Engine internals (`Symbol.toStringTag`, `Symbol.toPrimitive`, inspect
    // hooks, etc.) read symbol-keyed properties — fall through to the
    // underlying null-proto target so stringification / inspection of the
    // indexer value stays well-behaved instead of throwing.
    get: (~target, ~prop) =>
      if typeof(prop) === #string {
        get(~prop=prop->(Utils.magic: unknown => string))
      } else {
        target->(Utils.magic: {..} => dict<unknown>)->Dict.getUnsafe(prop->Utils.magic)
      },
    ownKeys: (~target as _) => keys,
    getOwnPropertyDescriptor: (~target as _, ~prop) =>
      if typeof(prop) === #string && keys->Array.includes(prop->(Utils.magic: unknown => string)) {
        Some({
          value: get(~prop=prop->(Utils.magic: unknown => string)),
          enumerable: true,
          configurable: true,
        })
      } else {
        None
      },
  }

  Utils.Proxy.make(Utils.Object.createNullObject(), traps)->(Utils.magic: {..} => 'indexer)
}

let startServer = (~getState, ~ctx: Ctx.t, ~isDevelopmentMode: bool) => {
  open Express

  let app = make()

  let consoleCorsMiddleware = (req, res, next) => {
    switch req.headers->Dict.get("origin") {
    | Some(origin) if origin === Env.prodEnvioAppUrl || origin === Env.envioAppUrl =>
      res->setHeader("Access-Control-Allow-Origin", origin)
    | _ => ()
    }

    res->setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
    res->setHeader("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept")

    if req.method === Rest.Options {
      res->sendStatus(200)
    } else {
      next()
    }
  }
  app->useFor("/console", consoleCorsMiddleware)
  app->useFor("/metrics", consoleCorsMiddleware)
  app->useFor("/metrics/runtime", consoleCorsMiddleware)

  app->get("/healthz", (_req, res) => {
    // this is the machine readable port used in kubernetes to check the health of this service.
    //   aditional health information could be added in the future (info about errors, back-offs, etc).
    res->sendStatus(200)
  })

  app->get("/console/state", (_req, res) => {
    let state = if isDevelopmentMode {
      getState()
    } else {
      Disabled({})
    }

    res->json(state->S.reverseConvertToJsonOrThrow(stateSchema))
  })

  app->post("/console/syncCache", (_req, res) => {
    if isDevelopmentMode {
      (ctx.persistence->Persistence.getInitializedStorageOrThrow).dumpEffectCache()
      ->Promise.thenResolve(_ => res->json(Boolean(true)))
      ->Promise.ignore
    } else {
      res->json(Boolean(false))
    }
  })

  let runtimeRegistry = PromClient.makeRegistry()
  PromClient.collectDefaultMetrics({"register": runtimeRegistry})

  app->get("/metrics", (_req, res) => {
    res->set("Content-Type", PromClient.defaultRegister->PromClient.getContentType)
    let _ =
      PromClient.defaultRegister
      ->PromClient.metrics
      ->Promise.thenResolve(metrics => res->endWithData(metrics))
  })

  app->get("/metrics/runtime", (_req, res) => {
    res->set("Content-Type", runtimeRegistry->PromClient.getContentType)
    let _ =
      runtimeRegistry
      ->PromClient.metrics
      ->Promise.thenResolve(metrics => res->endWithData(metrics))
  })

  let server = app->listen(Env.serverPort)
  server->Express.onError(err => {
    let code = (err->(Utils.magic: JsExn.t => {..}))["code"]
    if code === "EADDRINUSE" {
      Logging.error(
        `Port ${Env.serverPort->Int.toString} is already in use. To fix this either:` ++
        `\n  1. Kill the process using the port: lsof -ti :${Env.serverPort->Int.toString} | xargs kill -9` ++ `\n  2. Use a different port by setting the ENVIO_INDEXER_PORT environment variable: ENVIO_INDEXER_PORT=9899 envio start`,
      )
    } else {
      Logging.errorWithExn(err, "Failed to start indexer server")
    }
    NodeJs.process->NodeJs.exitWithCode(Failure)
  })
}

type args = {@as("tui-off") tuiOff?: bool}

type process
@val external process: process = "process"
@get external argv: process => 'a = "argv"

type mainArgs = Yargs.parsedArgs<args>

type migrateOpts = {reset: bool, persistedState: JSON.t}

let migrate = async (~reset, ~persistedState) => {
  let config = Config.loadWithoutRegistrations()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  await persistence->Persistence.init(~reset, ~chainConfigs=config.chainMap->ChainMap.values)
  await Core.upsertPersistedState(persistedState->JSON.stringify)
}

let dropSchema = async () => {
  let config = Config.loadWithoutRegistrations()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  await persistence.storage.reset()
}

let start = async (
  ~persistence: option<Persistence.t>=?,
  ~migrate: option<migrateOpts>=?,
  ~isTest=false,
  ~exitAfterFirstEventBlock=false,
  ~patchConfig: option<(Config.t, HandlerRegister.registrations) => Config.t>=?,
) => {
  let mainArgs: mainArgs = process->argv->Yargs.hideBin->Yargs.yargs->Yargs.argv
  let shouldUseTui = !isTest && !(mainArgs.tuiOff->Belt.Option.getWithDefault(Env.tuiOffEnvVar))
  // isDevelopmentMode controls whether the indexer stays alive after all
  // chains finish (keepProcessAlive) and whether the console API is exposed.
  // Set by `envio dev` via the ENVIO_DEV_MODE env var; `envio start` leaves
  // it unset so the process exits cleanly when indexing completes.
  let isDevelopmentMode = !isTest && Envio.isDevMode()

  // Initialize persistence first so the exported indexer value contains state from the database
  // when handler files are loaded (they may access the indexer at module top level).
  // `migrate`, when provided, folds the DB setup into this single `init()` call
  // (no separate `db setup` → `start` double-init).
  let configWithoutRegistrations = Config.loadWithoutRegistrations()
  let persistence = switch persistence {
  | Some(p) => p
  | None => PgStorage.makePersistenceFromConfig(~config=configWithoutRegistrations)
  }
  globalPersistenceRef := Some(persistence)
  let reset = migrate->Option.map(m => m.reset)->Option.getOr(false)
  await persistence->Persistence.init(
    ~reset,
    ~chainConfigs=configWithoutRegistrations.chainMap->ChainMap.values,
  )
  switch migrate {
  | Some({persistedState}) => await Core.upsertPersistedState(persistedState->JSON.stringify)
  | None => ()
  }

  // Register all handlers. The returned config has handler/contractRegister/
  // eventFilters baked into each event config. Downstream code uses this
  // enriched value; `Config.loadWithoutRegistrations` itself never sees
  // registration state.
  let (config, registrations) = await HandlerLoader.registerAllHandlers(
    ~config=configWithoutRegistrations,
  )
  let config = if isTest {
    {...config, shouldRollbackOnReorg: false}
  } else {
    config
  }

  let config = switch patchConfig {
  | Some(patchConfig) => patchConfig(config, registrations)
  | None => config
  }
  let ctx = {
    Ctx.registrations,
    config,
    persistence,
  }

  let envioVersion = Utils.EnvioPackage.value.version
  Prometheus.Info.set(~version=envioVersion)
  Prometheus.ProcessStartTimeSeconds.set()
  Prometheus.RollbackEnabled.set(~enabled=ctx.config.shouldRollbackOnReorg)

  if !isTest {
    startServer(~ctx, ~isDevelopmentMode, ~getState=() =>
      switch globalGsManagerRef.contents {
      | None => Initializing({})
      | Some(gsManager) => {
          let state = gsManager->GlobalStateManager.getState
          let chains =
            state.chainManager.chainFetchers
            ->ChainMap.values
            ->Array.map(cf => {
              let {fetchState} = cf
              let latestFetchedBlockNumber = Pervasives.max(
                FetchState.bufferBlockNumber(fetchState),
                0,
              )
              let knownHeight =
                cf->ChainFetcher.hasProcessedToEndblock
                  ? cf.fetchState.endBlock->Option.getOr(cf.fetchState.knownHeight)
                  : cf.fetchState.knownHeight

              {
                chainId: cf.chainConfig.id->Int.toFloat,
                poweredByHyperSync: (
                  cf.sourceManager->SourceManager.getActiveSource
                ).poweredByHyperSync,
                latestFetchedBlockNumber,
                knownHeight,
                numBatchesFetched: 0,
                startBlock: cf.fetchState.startBlock,
                endBlock: cf.fetchState.endBlock,
                firstEventBlockNumber: cf.fetchState.firstEventBlock,
                latestProcessedBlock: cf.committedProgressBlockNumber === -1
                  ? None
                  : Some(cf.committedProgressBlockNumber),
                timestampCaughtUpToHeadOrEndblock: cf.timestampCaughtUpToHeadOrEndblock,
                numEventsProcessed: cf.numEventsProcessed,
                numAddresses: cf.fetchState->FetchState.numAddresses,
              }
            })
          Active({
            envioVersion,
            chains,
            indexerStartTime: state.indexerStartTime,
            isPreRegisteringDynamicContracts: false,
            rollbackOnReorg: ctx.config.shouldRollbackOnReorg,
            isUnorderedMultichainMode: switch ctx.config.multichain {
            | Unordered => true
            | Ordered => false
            },
          })
        }
      }
    )
  }

  let chainManager = ChainManager.makeFromDbState(
    ~initialState=ctx.persistence->Persistence.getInitializedState,
    ~config=ctx.config,
    ~registrations=ctx.registrations,
  )
  let globalState = GlobalState.make(
    ~ctx,
    ~chainManager,
    ~isDevelopmentMode,
    ~shouldUseTui,
    ~exitAfterFirstEventBlock,
  )
  let gsManager = globalState->GlobalStateManager.make
  if shouldUseTui {
    let _rerender = Tui.start(~getState=() => gsManager->GlobalStateManager.getState)
  }
  globalGsManagerRef := Some(gsManager)
  gsManager->GlobalStateManager.dispatchTask(NextQuery(CheckAllChains))
  /*
    NOTE:
      This `ProcessEventBatch` dispatch shouldn't be necessary but we are adding for safety, it should immediately return doing 
      nothing since there is no events on the queues.
 */

  gsManager->GlobalStateManager.dispatchTask(ProcessEventBatch)
}
