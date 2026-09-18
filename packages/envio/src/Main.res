let getIndexerState = () =>
  EnvioGlobal.value.indexerState->(Utils.magic: option<unknown> => option<IndexerState.t>)
let setIndexerState = (state: IndexerState.t) =>
  EnvioGlobal.value.indexerState = Some(state->(Utils.magic: IndexerState.t => unknown))

// Persistence is set by Main.start before handler modules load, so that
// the exported indexer value can lazily expose DB state (startBlock,
// endBlock, isRealtime, dynamic contract addresses) once it's ready.
let getGlobalPersistence = () =>
  EnvioGlobal.value.persistence->(Utils.magic: option<unknown> => option<Persistence.t>)
let setGlobalPersistence = (persistence: Persistence.t) =>
  EnvioGlobal.value.persistence = Some(persistence->(Utils.magic: Persistence.t => unknown))

let getInitialState = (): option<Persistence.initialState> => {
  switch getGlobalPersistence() {
  | Some(persistence) =>
    switch persistence.storageStatus {
    | Ready(initialState) => Some(initialState)
    | _ => None
    }
  | None => None
  }
}

let getInitialChainState = (~chainId: ChainId.t): option<Persistence.initialChainState> =>
  getInitialState()->Option.flatMap(initialState =>
    initialState.chains->Array.find(c => c.id === chainId)
  )

// Importing `generated` must not trigger `Config.load()`,
// so the exported indexer calls this lazily on first `indexer.chains` access.
let buildChainsObject = (~config: Config.t) => {
  let chainIds = []
  let chains = Utils.Object.createNullObject()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    let chainIdStr = chainConfig.id->ChainId.toString

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
          // Only before persistence is ready, which in a real run is before any
          // handler module has loaded. The test indexer sits here for good.
          | None => chainConfig->Config.startBlockOrZero
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
          switch getIndexerState() {
          | Some(state) => state->IndexerState.isRealtime
          // Before the global state is available (eg during handler
          // module load after resume), derive from persistence: every chain
          // must have previously caught up to head or endBlock.
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
            switch getIndexerState() {
            | Some(state) => {
                let chainState = state->IndexerState.getChainState(~chainId=chainConfig.id)
                chainState->ChainState.contractAddresses(~contractName=contract.name)
              }
            // Before the global state is available (eg during handler
            // module load after resume), read them off what persistence
            // restored — which already holds the config's own addresses
            // alongside the dynamically registered ones.
            | None =>
              switch getInitialState() {
              | Some(initialState) =>
                switch initialState.chains->Array.find(c => c.id === chainConfig.id) {
                | Some(chainState) =>
                  chainState.addressRows->AddressRows.renderOfContract(
                    ~ecosystem=(config.ecosystem.name :> string),
                    ~shouldChecksum=!config.lowercaseAddresses,
                    ~contractId=initialState.contractMapping->ContractMapping.idOfOrThrow(
                      contract.name,
                    ),
                  )
                | None => contract.addresses
                }
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
  // - From TypeScript: { contract: "X", event: "Y", wildcard?, where?, fields? }
  // - From ReScript GADT: { event: { contract: "X", _0: "Y" }, wildcard?, where?, fields? }
  let parseIdentityConfig = (identityConfig: 'a) => {
    let raw =
      identityConfig->(
        Utils.magic: 'a => {
          "contract": unknown,
          "event": unknown,
          "wildcard": option<bool>,
          "where": option<JSON.t>,
          "fields": option<unknown>,
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
    let fields = raw["fields"]
    let eventOptions: option<Internal.eventOptions<_>> = switch (wildcard, where, fields) {
    | (None, None, None) => None
    | (wildcard, where, fields) =>
      Some({
        ?wildcard,
        where: ?(where->(Utils.magic: option<JSON.t> => option<_>)),
        ?fields,
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
        Utils.magic: 'a => {
          "program": unknown,
          "instruction": unknown,
          "where": option<JSON.t>,
          "fields": option<unknown>,
        }
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
    let fields = raw["fields"]
    let eventOptions: option<Internal.eventOptions<_>> = switch (where, fields) {
    | (None, None) => None
    | (where, fields) =>
      Some({
        where: ?(where->(Utils.magic: option<JSON.t> => option<_>)),
        ?fields,
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
    let raw = rawOptions->(Utils.magic: 'a => {"name": string, "where": unknown})
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
        chainIds->(Utils.magic: array<ChainId.t> => unknown)
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

// The RPC-stripped public config that the storage layer persists in
// `envio_info` (on initialize) and validates against (on resume).
let migrate = async (~reset) => {
  let config = Config.load()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  await persistence->Persistence.init(
    ~reset,
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~envioInfo=Config.envioInfo(),
    ~resetCommand="envio local db-migrate setup",
    ~runCommand=None,
    ~lowercaseAddresses=config.lowercaseAddresses,
    // A migration command runs once and exits, with nobody watching it recover:
    // an unreachable chain should say so now rather than hold the command open.
    ~startBlockRetry=StartBlockResolver.Once,
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

%%private(
  let startIndexer = async (
    ~config: Config.t,
    ~persistence: option<Persistence.t>=?,
    ~reset=false,
    ~isTest=false,
    ~exitAfterFirstEventBlock=false,
    ~patchConfig: option<(Config.t, HandlerRegister.registrationsByChainId) => Config.t>=?,
  ) => {
    // A worker reports to its supervisor, which draws for the whole run.
    let shouldUseTui = Tui.shouldUse(~suppressed=isTest || Worker.isEnabled)
    // In per-chain mode every line this process writes belongs to the chains it
    // drives, whether or not a supervisor split the run across processes.
    config->Config.logContext->Option.forEach(Logging.setContext)
    // isDevelopmentMode controls whether the indexer stays alive after all
    // chains finish (keepProcessAlive) and whether the console API is exposed.
    // Set by `envio dev` via the public config's `isDev` field; `envio start`
    // leaves it false so the process exits cleanly when indexing completes.
    let isDevelopmentMode = !isTest && config.isDev
    // Initialized first so the exported indexer value contains state from the
    // database when handler files are loaded (they may access the indexer at
    // module top level).
    let persistence = switch persistence {
    | Some(p) => p
    | None => PgStorage.makePersistenceFromConfig(~config)
    }
    setGlobalPersistence(persistence)
    await persistence->Persistence.initForRun(
      ~config,
      ~reset,
      ~isDevelopmentMode,
      ~requireInitialized=config.isolated,
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

    let getMetrics = () => getIndexerState()->Option.map(IndexerState.toMetrics)
    let dumpEffectCache = () =>
      (persistence->Persistence.getInitializedStorageOrThrow).dumpEffectCache()

    // A worker reports through its supervisor, which owns the one server and the
    // one display the run has.
    if !isTest && !Worker.isEnabled {
      Metrics.startRuntimeCollectors()
      Server.startServer(
        ~onSyncCache=() => dumpEffectCache()->Promise.thenResolve(ignore),
        ~collectRuntime=Metrics.collectRuntime,
        ~isDevelopmentMode,
        ~envioVersion,
        ~getMetrics,
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
      ~holdRealtime=Worker.config->Option.mapOr(false, worker => worker.holdRealtime),
      ~onError,
    )
    if shouldUseTui {
      let _rerender = Tui.start(~config, ~getMetrics=() => state->IndexerState.toMetrics)
    }
    Worker.bindRun(
      ~getMetrics=() => state->IndexerState.toMetrics,
      ~onReleaseRealtime=() => state->IndexerState.releaseRealtime,
    )
    setIndexerState(state)
    state->IndexerLoop.start
    await runUntilFatalError
  }
)

// Starts this process's part of a run: the group's supervisor when the budget
// and the schema afford splitting the chains across processes, and the indexer
// itself otherwise. A worker is already one process's part, so it never splits
// again — `planForRun` refuses an isolated config.
let start = async (
  ~persistence: option<Persistence.t>=?,
  ~reset=false,
  ~isTest=false,
  ~exitAfterFirstEventBlock=false,
  ~patchConfig: option<(Config.t, HandlerRegister.registrationsByChainId) => Config.t>=?,
) => {
  // A worker parses the same config its supervisor did and narrows it to the
  // chains it was handed, rather than being told what to index: the storage it
  // resumes refuses a config that disagrees with the one the run was created
  // from, which is a stronger guarantee than a handover could give.
  Worker.config->Option.forEach(({chainIds}) =>
    Config.prime(Config.getPublicConfigJson()->Config.withIsolatedChains(~chainIds))
  )
  let config = Config.load()
  switch isTest ? None : Supervisor.planForRun(~config) {
  | Some(workers) => await Supervisor.run(~config, ~workers, ~reset)
  | None =>
    await startIndexer(
      ~config,
      ~persistence?,
      ~reset,
      ~isTest,
      ~exitAfterFirstEventBlock,
      ~patchConfig?,
    )
  }
}
