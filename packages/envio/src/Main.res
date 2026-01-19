open Belt

type chainData = {
  chainId: float,
  poweredByHyperSync: bool,
  firstEventBlockNumber: option<int>,
  latestProcessedBlock: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  numEventsProcessed: int,
  latestFetchedBlockNumber: int,
  // Need this for API backwards compatibility
  @as("currentBlockHeight")
  knownHeight: int,
  numBatchesFetched: int,
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
  numEventsProcessed: s.matches(S.int),
  latestFetchedBlockNumber: s.matches(S.int),
  knownHeight: s.matches(S.int),
  numBatchesFetched: s.matches(S.int),
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
    ->Utils.Object.definePropertyWithValue(
      "startBlock",
      {enumerable: true, value: chainConfig.startBlock},
    )
    ->Utils.Object.definePropertyWithValue(
      "endBlock",
      {enumerable: true, value: chainConfig.endBlock},
    )
    ->Utils.Object.definePropertyWithValue("name", {enumerable: true, value: chainConfig.name})
    ->Utils.Object.defineProperty(
      "isLive",
      {
        enumerable: true,
        get: () => {
          switch globalGsManagerRef.contents {
          | None => false
          | Some(gsManager) =>
            let state = gsManager->GlobalStateManager.getState
            let chain = ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)
            let chainFetcher = state.chainManager.chainFetchers->ChainMap.get(chain)
            chainFetcher->ChainFetcher.isLive
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
            | None => contract.addresses
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

  indexer->Utils.magic
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

  PromClient.collectDefaultMetrics()

  app->get("/metrics", (_req, res) => {
    res->set("Content-Type", PromClient.defaultRegister->PromClient.getContentType)
    let _ =
      PromClient.defaultRegister
      ->PromClient.metrics
      ->Promise.thenResolve(metrics => res->endWithData(metrics))
  })

  let _ = app->listen(Env.serverPort)
}

type args = {@as("tui-off") tuiOff?: bool}

type process
@val external process: process = "process"
@get external argv: process => 'a = "argv"

type mainArgs = Yargs.parsedArgs<args>

let start = async (
  ~makeGeneratedConfig: unit => Config.t,
  ~persistence: Persistence.t,
  ~isTest=false,
) => {
  let mainArgs: mainArgs = process->argv->Yargs.hideBin->Yargs.yargs->Yargs.argv
  let shouldUseTui = !isTest && !(mainArgs.tuiOff->Belt.Option.getWithDefault(Env.tuiOffEnvVar))
  // The most simple check to verify whether we are running in development mode
  // and prevent exposing the console to public, when creating a real deployment.
  // Note: isTest overrides isDevelopmentMode to ensure proper process exit in test mode.
  let isDevelopmentMode = !isTest && Env.Db.password === "testing"

  // Register all handlers first, then get the config with registrations
  let configWithoutRegistrations = makeGeneratedConfig()
  let registrations = await HandlerLoader.registerAllHandlers(~config=configWithoutRegistrations)
  let config = makeGeneratedConfig()
  let config = if isTest {
    {...config, shouldRollbackOnReorg: false}
  } else {
    config
  }
  let ctx = {
    Ctx.registrations,
    config,
    persistence,
  }

  let envioVersion = Utils.EnvioPackage.value.version
  Prometheus.Info.set(~version=envioVersion)
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
                numBatchesFetched: cf.numBatchesFetched,
                endBlock: cf.fetchState.endBlock,
                firstEventBlockNumber: cf.firstEventBlockNumber,
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

  await ctx.persistence->Persistence.init(~chainConfigs=ctx.config.chainMap->ChainMap.values)

  let chainManager = await ChainManager.makeFromDbState(
    ~initialState=ctx.persistence->Persistence.getInitializedState,
    ~config=ctx.config,
    ~registrations=ctx.registrations,
  )
  let globalState = GlobalState.make(~ctx, ~chainManager, ~isDevelopmentMode, ~shouldUseTui)
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
