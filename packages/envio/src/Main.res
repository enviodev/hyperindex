open Belt

type chainData = {
  chainId: float,
  poweredByHyperSync: bool,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
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
      indexerStartTime: Js.Date.t,
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

let globalGsManagerRef: ref<option<GlobalStateManager.t>> = ref(None)

// Persistence is set by Main.start before handler modules load, so that
// the exported indexer value can lazily expose DB state (startBlock,
// endBlock, isLive, dynamic contract addresses) once it's ready.
let globalPersistenceRef: ref<option<Persistence.t>> = ref(None)

let getInitialChainState = (~chainId: int): option<Persistence.initialChainState> => {
  switch globalPersistenceRef.contents {
  | Some(persistence) =>
    switch persistence.storageStatus {
    | Ready(initialState) => initialState.chains->Js.Array2.find(c => c.id === chainId)
    | _ => None
    }
  | None => None
  }
}

let getGlobalIndexer = (~config: Config.t): 'indexer => {
  let indexer = Utils.Object.createNullObject()

  indexer
  ->Utils.Object.definePropertyWithValue("name", {enumerable: true, value: config.name})
  ->Utils.Object.definePropertyWithValue(
    "description",
    {enumerable: true, value: config.description},
  )
  ->ignore

  let chainIds = []

  // Build chains object with chain ID as string key
  let chains = Utils.Object.createNullObject()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    let chainIdStr = chainConfig.id->Int.toString

    chainIds->Js.Array2.push(chainConfig.id)->ignore

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
                let indexingContracts = chainFetcher.fetchState.indexingContracts

                // Collect all addresses for this contract name from indexingContracts
                let addresses = []
                let values = indexingContracts->Js.Dict.values
                for idx in 0 to values->Array.length - 1 {
                  let indexingContract = values->Js.Array2.unsafe_get(idx)
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
                chainState.dynamicContracts->Array.forEach(
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
  indexer
  ->Utils.Object.definePropertyWithValue("chainIds", {enumerable: true, value: chainIds})
  ->ignore
  indexer->Utils.Object.definePropertyWithValue("chains", {enumerable: true, value: chains})->ignore

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
          "where": option<Js.Json.t>,
        }
      )
    // Detect format: if "contract" is a string, it's the TS format
    let (contractName, eventName) = if Js.typeof(raw["contract"]) === "string" {
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
        where: ?where->(Utils.magic: option<Js.Json.t> => option<_>),
      })
    }
    (contractName, eventName, eventOptions)
  }

  // onEvent: delegates to HandlerRegister.setHandler
  let onEventFn = (identityConfig: 'a, handler: 'b) => {
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

  // Extract {_gte, _lte, _every} from the user-returned filter. Path differs
  // per ecosystem to match the handler-arg shape users see:
  //   - EVM:  raw.block.number.{_gte,_lte,_every}   (matches `block.number`)
  //   - Fuel: raw.block.height.{_gte,_lte,_every}   (matches `block.height`)
  //   - SVM:  raw.{_gte,_lte,_every}                (flat; matches `slot`)
  // Full TS-level schemas live in `packages/envio/index.d.ts`.
  let extractRange = (filter: unknown): (option<int>, option<int>, int) => {
    let numberFilter = switch config.ecosystem.name {
    | Evm =>
      filter
      ->(Utils.magic: unknown => {"block": option<{"number": option<unknown>}>})
      ->(r => r["block"])
      ->Belt.Option.flatMap(b => b["number"])
    | Fuel =>
      filter
      ->(Utils.magic: unknown => {"block": option<{"height": option<unknown>}>})
      ->(r => r["block"])
      ->Belt.Option.flatMap(b => b["height"])
    | Svm => Some(filter)
    }
    switch numberFilter {
    | None => (None, None, 1)
    | Some(n) =>
      let typed =
        n->(
          Utils.magic: unknown => {"_gte": option<int>, "_lte": option<int>, "_every": option<int>}
        )
      (typed["_gte"], typed["_lte"], typed["_every"]->Belt.Option.getWithDefault(1))
    }
  }

  // `where` is evaluated once per configured chain at registration time.
  // Decoded ranges/stride feed directly into `HandlerRegister.registerOnBlock`
  // so the fetcher's `(blockNumber - handlerStartBlock) % interval === 0`
  // math at `FetchState.res:619` stays untouched.
  // SVM exposes the block handler as `indexer.onSlot` (blocks on SVM are
  // slots); EVM/Fuel expose it as `indexer.onBlock`. Used for both the
  // attached property name and any user-facing error messages so the cited
  // call-site matches what the user wrote.
  let onBlockMethodName = switch config.ecosystem.name {
  | Svm => "onSlot"
  | Evm | Fuel => "onBlock"
  }

  let onBlockHandlerFn = (rawOptions: 'a, handler: 'b) => {
    let raw =
      rawOptions->(
        Utils.magic: 'a => {
          "name": string,
          "where": option<Envio.onBlockWhereArgs<unknown> => unknown>,
        }
      )
    let typedHandler = handler->(Utils.magic: 'b => Internal.onBlockArgs => promise<unit>)
    let chainsDict = chains->(Utils.magic: {..} => dict<unknown>)
    let name = raw["name"]
    let logger = Logging.createChild(~params={"onBlock": name})

    // `where` must be a function (unlike onEvent, which also accepts a static
    // value). A static value would have to be evaluated against every chain
    // independently, which has no useful semantic for block handlers.
    switch raw["where"]->(Utils.magic: option<'a> => unknown) {
    | w if w === %raw(`undefined`) || w === %raw(`null`) => ()
    | w if Js.typeof(w) === "function" => ()
    | w =>
      Js.Exn.raiseError(
        `\`indexer.${onBlockMethodName}("${name}")\` expected \`where\` to be a function or omitted, but got ${Js.typeof(
            w,
          )}.`,
      )
    }

    let matchedAny = ref(false)

    config.chainMap
    ->ChainMap.values
    ->Array.forEach(chainConfig => {
      let chainId = chainConfig.id
      let chainObj = chainsDict->Js.Dict.unsafeGet(chainId->Int.toString)

      // Predicate returns `undefined`/`true` → match with no filter;
      // `false` → skip; any plain object → structured filter.
      let result = switch raw["where"] {
      | None => %raw(`true`)
      | Some(predicate) => predicate({chain: chainObj})
      }

      let (shouldRegister, startBlock, endBlock, interval) = if (
        result === %raw(`true`) || result === %raw(`undefined`) || result === %raw(`null`)
      ) {
        (true, None, None, 1)
      } else if result === %raw(`false`) {
        (false, None, None, 1)
      } else if Js.typeof(result) === "object" && !(result->Js.Array2.isArray) {
        let (gte, lte, every) = extractRange(result)
        (true, gte, lte, every)
      } else {
        // Reject numbers, strings, functions, arrays, etc. — anything that
        // isn't bool/undefined/null/plain-object would silently misregister.
        Js.Exn.raiseError(
          `\`indexer.${onBlockMethodName}("${name}")\` \`where\` predicate returned an invalid value of type ${Js.typeof(
              result,
            )}. Expected boolean, undefined, or a filter object.`,
        )
      }

      if shouldRegister {
        matchedAny := true
        HandlerRegister.registerOnBlock(
          ~name,
          ~chainId,
          ~interval,
          ~startBlock,
          ~endBlock,
          ~handler=typedHandler,
        )
      }
    })

    // Catches misconfigured `where` predicates that return `false` for every
    // configured chain — the handler would otherwise never fire with no hint.
    if !matchedAny.contents {
      logger->Logging.childWarn("Block handler matched 0 chains. Check the `where` predicate.")
    }
  }

  indexer
  ->Utils.Object.definePropertyWithValue("onEvent", {enumerable: true, value: onEventFn})
  ->Utils.Object.definePropertyWithValue(
    "contractRegister",
    {enumerable: true, value: contractRegisterFn},
  )
  ->Utils.Object.definePropertyWithValue(
    onBlockMethodName,
    {enumerable: true, value: onBlockHandlerFn},
  )
  ->ignore

  indexer->(Utils.magic: 'a => 'indexer)
}

let startServer = (~getState, ~ctx: Ctx.t, ~isDevelopmentMode: bool) => {
  open Express

  let app = make()

  let consoleCorsMiddleware = (req, res, next) => {
    switch req.headers->Js.Dict.get("origin") {
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
      ->Promise.done
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
    let code = (err->(Utils.magic: Js.Exn.t => {..}))["code"]
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

let start = async (
  ~makeGeneratedConfig: unit => Config.t,
  ~persistence: option<Persistence.t>=?,
  ~isTest=false,
  ~exitAfterFirstEventBlock=false,
  ~patchConfig: option<(Config.t, HandlerRegister.registrations) => Config.t>=?,
) => {
  let mainArgs: mainArgs = process->argv->Yargs.hideBin->Yargs.yargs->Yargs.argv
  let shouldUseTui = !isTest && !(mainArgs.tuiOff->Belt.Option.getWithDefault(Env.tuiOffEnvVar))
  // The most simple check to verify whether we are running in development mode
  // and prevent exposing the console to public, when creating a real deployment.
  // Note: isTest overrides isDevelopmentMode to ensure proper process exit in test mode.
  let isDevelopmentMode = !isTest && Env.Db.password === "testing"

  // Initialize persistence first so the exported indexer value contains state from the database
  // when handler files are loaded (they may access the indexer at module top level).
  let configWithoutRegistrations = makeGeneratedConfig()
  let persistence = switch persistence {
  | Some(p) => p
  | None => PgStorage.makePersistenceFromConfig(~config=configWithoutRegistrations)
  }
  globalPersistenceRef := Some(persistence)
  await persistence->Persistence.init(
    ~chainConfigs=configWithoutRegistrations.chainMap->ChainMap.values,
  )

  // Register all handlers, then get the config with registrations
  let registrations = await HandlerLoader.registerAllHandlers(~config=configWithoutRegistrations)
  let config = makeGeneratedConfig()
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
                  ? cf.fetchState.endBlock->Option.getWithDefault(cf.fetchState.knownHeight)
                  : cf.fetchState.knownHeight

              {
                chainId: cf.chainConfig.id->Js.Int.toFloat,
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

  let chainManager = await ChainManager.makeFromDbState(
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
