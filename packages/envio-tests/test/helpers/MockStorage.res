type method = [
  | #holding
  | #initialize
  | #readStoredConfig
  | #resumeInitialState
  | #dumpEffectCache
  | #loadOrThrow
]

type t = {
  holdingCalls: array<bool>,
  resolveHolding: Persistence.holding => unit,
  initializeCalls: array<{
    "entities": array<Internal.entityConfig>,
    "chainConfigs": array<Config.chain>,
    "enums": array<Table.enumConfig<Table.enum>>,
    "envioInfo": JSON.t,
  }>,
  resolveInitialize: Persistence.initialState => unit,
  resumeInitialStateCalls: array<bool>,
  resolveLoadInitialState: Persistence.initialState => unit,
  loadOrThrowCalls: array<{"filter": dict<dict<unknown>>, "tableName": string}>,
  dumpEffectCacheCalls: ref<int>,
  storage: Persistence.storage,
}

// What a resume finds stored: by default, a storage an empty config built.
let emptyStored: ResumePlan.stored = {
  envioInfo: Some(JSON.Encode.object(Dict.make())),
  chains: [],
  contractMapping: ContractMapping.empty,
}

let make = (methods: array<method>, ~dbEntities=[], ~stored=emptyStored) => {
  let implement = (method: method, fn) => {
    if methods->Array.includes(method) {
      fn
    } else {
      (() => JsError.throwWithMessage(`storage.${(method :> string)} not implemented`))->Obj.magic
    }
  }

  let implementBody = (method: method, fn) => {
    if methods->Array.includes(method) {
      fn()
    } else {
      JsError.throwWithMessage(`storage.${(method :> string)} not implemented`)
    }
  }

  let holdingCalls = []
  let initializeCalls = []
  let holdingResolveFns = []
  let initializeResolveFns = []
  let loadOrThrowCalls = []
  let dumpEffectCacheCalls = ref(0)
  let resumeInitialStateCalls = []
  let resumeInitialStateResolveFns = []

  {
    holdingCalls,
    initializeCalls,
    loadOrThrowCalls,
    dumpEffectCacheCalls,
    resumeInitialStateCalls,
    resolveLoadInitialState: (initialState: Persistence.initialState) => {
      resumeInitialStateResolveFns->Array.forEach(resolve => resolve(initialState))
    },
    resolveHolding: holding => {
      holdingResolveFns->Array.forEach(resolve => resolve(holding))
    },
    resolveInitialize: (initialState: Persistence.initialState) => {
      initializeResolveFns->Array.forEach(resolve => resolve(initialState))
    },
    storage: {
      name: "mock",
      entityStoreName: _ => "mock",
      holding: implement(#holding, () => {
        holdingCalls->Array.push(true)->ignore
        Promise.make((resolve, _reject) => {
          holdingResolveFns->Array.push(resolve)->ignore
        })
      }),
      initialize: implement(#initialize, (
        ~chainConfigs=[],
        ~entities=[],
        ~enums=[],
        ~contractMapping as _,
        ~envioInfo,
      ) => {
        initializeCalls
        ->Array.push({
          "entities": entities,
          "chainConfigs": chainConfigs,
          "enums": enums,
          "envioInfo": envioInfo,
        })
        ->ignore
        Promise.make((resolve, _reject) => {
          initializeResolveFns->Array.push(resolve)->ignore
        })
      }),
      readStoredConfig: implement(#readStoredConfig, () => Promise.resolve(stored)),
      addChain: (~chainConfig as _, ~entities as _, ~contractMapping as _) =>
        JsError.throwWithMessage("Not implemented"),
      resumeInitialState: implement(#resumeInitialState, (
        ~entities as _,
        ~chainIds as _,
        ~contractMapping as _,
      ) => {
        resumeInitialStateCalls->Array.push(true)->ignore
        Promise.make((resolve, _reject) => {
          resumeInitialStateResolveFns->Array.push(resolve)->ignore
        })
      }),
      dumpEffectCache: implement(#dumpEffectCache, () => {
        dumpEffectCacheCalls := dumpEffectCacheCalls.contents + 1
        Promise.resolve()
      }),
      loadOrThrow: (~filter, ~table: Table.table) => {
        implementBody(#loadOrThrow, () => {
          loadOrThrowCalls
          ->Array.push({
            "filter": filter->EntityFilter.entries,
            "tableName": table.tableName,
          })
          ->ignore
          let rows = switch dbEntities->Array.find(((entityConfig: Internal.entityConfig, _)) =>
            entityConfig.table.tableName === table.tableName
          ) {
          | Some((_, rows)) =>
            let matcher = filter->EntityFilter.makeMatcher(~table)
            rows->Array.filter(row => matcher(row->(Utils.magic: 'entity => Internal.entity)))
          | None => []
          }
          Promise.resolve(rows->(Utils.magic: array<'entity> => array<unknown>))
        })
      },
      ensureQueryIndexes: (~entityConfig as _, ~scope as _, ~filters as _) => Promise.resolve(),
      ensureSchemaIndexes: (~entities as _, ~chainIds as _) => Promise.resolve(),
      finalizeBackfill: (~entities as _, ~chainIds as _, ~readyAt as _) => Promise.resolve(),
      reset: () => JsError.throwWithMessage("Not implemented"),
      setChainMeta: _ => JsError.throwWithMessage("Not implemented"),
      pruneStaleCheckpoints: async (~safeCheckpoints as _) => (),
      pruneStaleEntityHistory: async (~entityConfig as _, ~safeCheckpoints as _) => (),
      getRollbackTargetCheckpoint: (
        ~reorgChainId as _,
        ~lastKnownValidBlockNumber as _,
        ~sequence as _,
      ) => JsError.throwWithMessage("Not implemented"),
      getRollbackProgressDiff: (~floors as _) => JsError.throwWithMessage("Not implemented"),
      getRollbackData: (~entityConfig as _, ~floors as _) =>
        JsError.throwWithMessage("Not implemented"),
      writeBatch: (
        ~batch as _,
        ~rollback as _,
        ~config as _,
        ~allEntities as _,
        ~updatedEffectsCache as _,
        ~updatedEntities as _,
        ~registeredAddresses as _,
        ~chainMetaData as _,
        ~onWrite as _,
      ) => JsError.throwWithMessage("Not implemented"),
      close: () => Promise.resolve(),
    },
  }
}

let toPersistence = (storageMock: t, ~config: Config.t) => {
  {
    ...Storage.makePersistenceFromConfig(
      ~logger=Logger.makeInMemory(),
      ~config,
      ~storage=storageMock.storage,
    ),
    storageStatus: Ready({
      cleanRun: false,
      contractMapping: config.contractMapping,
      cache: Dict.make(),
      chains: [],
      reorgCheckpoints: [],
      checkpointFrontier: Frontier.empty(),
    }),
  }
}
