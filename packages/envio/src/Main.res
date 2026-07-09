type chainData = ChainState.chainData
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
    rollbackOnReorg: s.matches(S.bool),
  })),
])

let indexerStateRef: ref<option<IndexerState.t>> = ref(None)

// Persistence is set by Main.start before handler modules load, so that
// the exported indexer value can lazily expose DB state (startBlock,
// endBlock, isRealtime, dynamic contract addresses) once it's ready.
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

// Importing `generated` must not trigger `Config.load()`,
// so the exported indexer calls this lazily on first `indexer.chains` access.
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
      "isRealtime",
      {
        enumerable: true,
        get: () => {
          switch indexerStateRef.contents {
          | Some(state) => state->IndexerState.isRealtime
          // Before the global state is available (eg during handler
          // module load after resume), derive from persistence: every chain
          // must have previously caught up to head or endBlock. Mirror the
          // IndexerState.makeFromDbState path: updateSyncTimeOnRestart wipes
          // the saved timestamps so a restart re-enters backfill.
          | None if Env.updateSyncTimeOnRestart => false
          | None =>
            config.chainMap
            ->ChainMap.values
            ->Array.every(c =>
              switch getInitialChainState(~chainId=c.id) {
              | Some(chainState) => chainState.timestampCaughtUpToHeadOrEndblock->Option.isSome
              | None => false
              }
            )
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
            switch indexerStateRef.contents {
            | Some(state) => {
                let chain = ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)
                let chainState = state->IndexerState.getChainState(~chain)
                chainState->ChainState.contractAddresses(~contractName=contract.name)
              }
            // Before the global state is available (eg during handler
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

  // SVM identity: `{program, instruction}` from TS or
  // `{instruction: GADT{contract, _0}}` from ReScript. Same two-format dance
  // as the EVM `parseIdentityConfig`, but reading the SVM-native field names.
  let parseSvmIdentityConfig = (identityConfig: 'a) => {
    let raw =
      identityConfig->(
        Utils.magic: 'a => {"program": unknown, "instruction": unknown, "where": option<JSON.t>}
      )
    let (programName, instructionName) = if typeof(raw["program"]) === #string {
      (
        raw["program"]->(Utils.magic: unknown => string),
        raw["instruction"]->(Utils.magic: unknown => string),
      )
    } else {
      let inst = raw["instruction"]->(Utils.magic: unknown => {"contract": string, "_0": string})
      (inst["contract"], inst["_0"])
    }
    let where = raw["where"]
    let eventOptions: option<Internal.eventOptions<_>> = switch where {
    | None => None
    | Some(_) =>
      Some({
        where: ?(where->(Utils.magic: option<JSON.t> => option<_>)),
      })
    }
    (programName, instructionName, eventOptions)
  }

  // onInstruction: delegates to HandlerRegister.setHandler. The SVM analog of
  // onEvent; the registration store keys on `(contractName, eventName)` which
  // for SVM is `(programName, instructionName)`.
  let onInstructionFn = (identityConfig: 'a, handler: 'b) => {
    HandlerRegister.throwIfFinishedRegistration(~methodName="onInstruction")
    let (programName, instructionName, eventOptions) = parseSvmIdentityConfig(identityConfig)
    // The generic dispatch hands every handler `{event, context}`. SVM handlers
    // receive the instruction under `instruction`, so remap the field here; the
    // payload object itself is the `svmInstruction` built in SvmHyperSyncSource.
    let userHandler =
      handler->(
        Utils.magic: 'b => Envio.svmOnInstructionArgs<Internal.handlerContext> => promise<unit>
      )
    HandlerRegister.setHandler(
      ~contractName=programName,
      ~eventName=instructionName,
      (args: Internal.genericHandlerArgs<Internal.event, Internal.handlerContext>) =>
        userHandler({
          instruction: args.event->(Utils.magic: Internal.event => Envio.svmInstruction),
          context: args.context,
        }),
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

  let onRollbackCommitFn = (callback: 'a) => {
    HandlerRegister.throwIfFinishedRegistration(
      ~methodName="~internalAndWillBeRemovedSoon_onRollbackCommit",
    )
    let _ = RollbackCommit.register(callback->(Utils.magic: 'a => RollbackCommit.callback))
  }

  let onBlockFn = (rawOptions: 'a, handler: 'b) => {
    HandlerRegister.throwIfFinishedRegistration(~methodName="onBlock")
    let raw =
      rawOptions->(
        Utils.magic: 'a => {
          "name": string,
          "where": unknown,
        }
      )
    HandlerRegister.registerOnBlock(
      ~name=raw["name"],
      ~where=raw["where"],
      ~handler=handler->(Utils.magic: 'b => Internal.onBlockArgs => promise<unit>),
      ~getChainsObject=config => {
        let (chains, _) = buildChainsObject(~config)
        chains->(Utils.magic: {..} => dict<unknown>)
      },
    )
  }

  // Ecosystem-specific surface: EVM/Fuel expose event + block handlers; SVM
  // exposes slot handlers only. The TS `.d.ts` already models this separation
  // — the Proxy mirrors it at runtime so `Object.keys(indexer)` reflects the
  // actually-callable methods and typos surface via the unknown-prop throw
  // rather than silent `undefined` returns.
  //
  // `Api.res` calls `getGlobalIndexer()` at envio-package load, so the keys
  // array is memoized lazily: an early `createEffect` / `S` import that
  // never touches the indexer must not trigger a config parse. The memo is
  // safe because `Config.load` is itself pure.
  let keysMemo: ref<option<array<string>>> = ref(None)
  let getKeys = () =>
    switch keysMemo.contents {
    | Some(k) => k
    | None => {
        let keys = switch Config.load().ecosystem.name {
        | Evm | Fuel => [
            "name",
            "description",
            "chainIds",
            "chains",
            "onEvent",
            "contractRegister",
            "onBlock",
            "~internalAndWillBeRemovedSoon_onRollbackCommit",
          ]
        | Svm => [
            "name",
            "description",
            "chainIds",
            "chains",
            "onInstruction",
            "onSlot",
            "~internalAndWillBeRemovedSoon_onRollbackCommit",
          ]
        }
        keysMemo := Some(keys)
        keys
      }
    }

  let get = (~prop: string) =>
    switch prop {
    | "name" => Config.load().name->(Utils.magic: string => unknown)
    | "description" => Config.load().description->(Utils.magic: option<string> => unknown)
    | "chainIds" => {
        let (_, chainIds) = buildChainsObject(~config=Config.load())
        chainIds->(Utils.magic: array<int> => unknown)
      }
    | "chains" => {
        let (chains, _) = buildChainsObject(~config=Config.load())
        chains->(Utils.magic: {..} => unknown)
      }
    | "onEvent" => onEventFn->Utils.magic
    | "onInstruction" => onInstructionFn->Utils.magic
    | "contractRegister" => contractRegisterFn->Utils.magic
    | "onBlock" | "onSlot" => onBlockFn->Utils.magic
    | "~internalAndWillBeRemovedSoon_onRollbackCommit" => onRollbackCommitFn->Utils.magic
    | _ =>
      JsError.throwWithMessage(
        `Field \`${prop}\` does not exist on \`indexer\`. Available fields: ${getKeys()->Array.join(
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
    ownKeys: (~target as _) => getKeys(),
    getOwnPropertyDescriptor: (~target as _, ~prop) =>
      if (
        typeof(prop) === #string &&
          getKeys()->Array.includes(prop->(Utils.magic: unknown => string))
      ) {
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

let startServer = (~getState, ~persistence: Persistence.t, ~isDevelopmentMode: bool) => {
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
      (persistence->Persistence.getInitializedStorageOrThrow).dumpEffectCache()
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
      Metrics.collect(~state=indexerStateRef.contents)->Promise.thenResolve(metrics =>
        res->endWithData(metrics)
      )
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

// The RPC-stripped public config that the storage layer persists in
// `envio_info` (on initialize) and validates against (on resume).
let getEnvioInfo = () => Config.getPublicConfigJson()->Config.stripSensitiveData

let migrate = async (~reset) => {
  let config = Config.load()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  await persistence->Persistence.init(
    ~reset,
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~envioInfo=getEnvioInfo(),
    ~resetCommand="envio local db-migrate setup",
    ~runCommand=None,
  )
  await persistence.storage.close()
}

let dropSchema = async () => {
  let config = Config.load()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  await persistence.storage.reset()
  await persistence.storage.close()
}

// Rejection carried by `onError`: the failure is already logged with full
// context, so callers should act on it (exit / re-throw) without logging again.
exception FatalError(exn)

let start = async (
  ~persistence: option<Persistence.t>=?,
  ~reset=false,
  ~isTest=false,
  ~exitAfterFirstEventBlock=false,
  ~patchConfig: option<(Config.t, HandlerRegister.registrationsByChainId) => Config.t>=?,
) => {
  let mainArgs: mainArgs = process->argv->Yargs.hideBin->Yargs.yargs->Yargs.argv
  let explicitTui = switch mainArgs.tuiOff {
  | Some(off) => Some(!off)
  | None => Env.tuiEnvVar
  }
  let shouldUseTui = switch (isTest, explicitTui) {
  | (true, _) => false
  | (_, Some(tui)) => tui
  | (_, None) => !Envio.isNonInteractive()
  }
  // Initialize persistence first so the exported indexer value contains state from the database
  // when handler files are loaded (they may access the indexer at module top level).
  let config = Config.load()
  // isDevelopmentMode controls whether the indexer stays alive after all
  // chains finish (keepProcessAlive) and whether the console API is exposed.
  // Set by `envio dev` via the public config's `isDev` field; `envio start`
  // leaves it false so the process exits cleanly when indexing completes.
  let isDevelopmentMode = !isTest && config.isDev
  let persistence = switch persistence {
  | Some(p) => p
  | None => PgStorage.makePersistenceFromConfig(~config)
  }
  globalPersistenceRef := Some(persistence)
  await persistence->Persistence.init(
    ~reset,
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~envioInfo=getEnvioInfo(),
    ~resetCommand=isDevelopmentMode ? "envio dev -r" : "envio start -r",
    ~runCommand=Some(isDevelopmentMode ? "envio dev" : "envio start"),
  )

  // Loads user handler files, which register handler/contractRegister/where
  // state into the global `HandlerRegister` registry as a side effect; this
  // returns that state resolved into per-chain registrations. `config` itself
  // is never mutated by registration — it holds only event definitions.
  let registrationsByChainId = await HandlerLoader.registerAllHandlers(~config)
  let config = if isTest {
    {...config, shouldRollbackOnReorg: false}
  } else {
    config
  }

  let config = switch patchConfig {
  | Some(patchConfig) => patchConfig(config, registrationsByChainId)
  | None => config
  }
  // The single fatal-error handler, invoked once via IndexerState.errorExit.
  // It logs the failure once (with chain context) and rejects the run wrapped in
  // `FatalError` so callers know it's already logged — `Bin.res` just exits, the
  // test worker unwraps and re-throws it to the parent thread. `runUntilFatalError`
  // only ever rejects: on a clean run it stays pending and the process exits via
  // ExitOnCaughtUp / when the indexer loop drains.
  let onErrorReject = ref(None)
  let runUntilFatalError: promise<unit> = Promise.make((_resolve, reject) =>
    onErrorReject := Some(reject)
  )
  // `onErrorReject` is filled synchronously by `Promise.make` above, before the
  // indexer can run and call `onError`, so it's always present here.
  let onError = (errHandler: ErrorHandling.t) => {
    errHandler->ErrorHandling.log
    (onErrorReject.contents->Option.getUnsafe)(FatalError(errHandler.exn->Utils.prettifyExn))
  }
  let envioVersion = Utils.EnvioPackage.value.version
  Prometheus.Info.set(~version=envioVersion)
  Prometheus.ProcessStartTimeSeconds.set()
  Prometheus.RollbackEnabled.set(~enabled=config.shouldRollbackOnReorg)

  if !isTest {
    startServer(~persistence, ~isDevelopmentMode, ~getState=() =>
      switch indexerStateRef.contents {
      | None => Initializing({})
      | Some(state) => {
          let chains =
            state->IndexerState.chainStates->Dict.valuesToArray->Array.map(ChainState.toChainData)
          Active({
            envioVersion,
            chains,
            indexerStartTime: state->IndexerState.indexerStartTime,
            isPreRegisteringDynamicContracts: false,
            rollbackOnReorg: config.shouldRollbackOnReorg,
          })
        }
      }
    )
  }

  let state = IndexerState.makeFromDbState(
    ~config,
    ~persistence,
    ~initialState=persistence->Persistence.getInitializedState,
    ~registrationsByChainId,
    ~isDevelopmentMode,
    ~shouldUseTui,
    ~exitAfterFirstEventBlock,
    ~onError,
  )
  if shouldUseTui {
    let _rerender = Tui.start(~getState=() => state)
  }
  indexerStateRef := Some(state)
  state->IndexerLoop.start
  await runUntilFatalError
}
