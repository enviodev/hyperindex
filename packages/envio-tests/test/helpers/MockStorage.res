type method = [
  | #isInitialized
  | #initialize
  | #resumeInitialState
  | #dumpEffectCache
  | #loadOrThrow
]

type t = {
  isInitializedCalls: array<bool>,
  resolveIsInitialized: bool => unit,
  initializeCalls: array<{
    "entities": array<Internal.entityConfig>,
    "chainConfigs": array<Config.chain>,
    "enums": array<Table.enumConfig<Table.enum>>,
    "envioInfo": JSON.t,
  }>,
  resolveInitialize: Persistence.initialState => unit,
  resumeInitialStateCalls: array<bool>,
  resolveLoadInitialState: Persistence.initialState => unit,
  loadOrThrowCalls: array<{"filter": EntityFilter.t, "tableName": string}>,
  ensureQueryIndexesCalls: array<{"tableName": string, "filters": array<EntityFilter.t>}>,
  finalizeBackfillCalls: array<{
    "entityNames": array<string>,
    "chainIds": array<ChainId.t>,
    "readyAt": Date.t,
  }>,
  dumpEffectCacheCalls: ref<int>,
  storage: Persistence.storage,
}

let make = (methods: array<method>, ~dbEntities=[]) => {
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

  let isInitializedCalls = []
  let initializeCalls = []
  let isInitializedResolveFns = []
  let initializeResolveFns = []
  let loadOrThrowCalls = []
  let ensureQueryIndexesCalls = []
  let finalizeBackfillCalls = []
  let dumpEffectCacheCalls = ref(0)
  let resumeInitialStateCalls = []
  let resumeInitialStateResolveFns = []

  {
    isInitializedCalls,
    initializeCalls,
    loadOrThrowCalls,
    ensureQueryIndexesCalls,
    finalizeBackfillCalls,
    dumpEffectCacheCalls,
    resumeInitialStateCalls,
    resolveLoadInitialState: (initialState: Persistence.initialState) => {
      resumeInitialStateResolveFns->Array.forEach(resolve => resolve(initialState))
    },
    resolveIsInitialized: bool => {
      isInitializedResolveFns->Array.forEach(resolve => resolve(bool))
    },
    resolveInitialize: (initialState: Persistence.initialState) => {
      initializeResolveFns->Array.forEach(resolve => resolve(initialState))
    },
    storage: {
      name: "mock",
      isInitialized: implement(#isInitialized, () => {
        isInitializedCalls->Array.push(true)->ignore
        Promise.make((resolve, _reject) => {
          isInitializedResolveFns->Array.push(resolve)->ignore
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
      resumeInitialState: implement(#resumeInitialState, () => {
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
            "filter": filter,
            "tableName": table.tableName,
          })
          ->ignore
          let rows = switch dbEntities->Array.find(((entityConfig: Internal.entityConfig, _)) =>
            entityConfig.table.tableName === table.tableName
          ) {
          | Some((_, rows)) =>
            rows->Array.filter(row =>
              filter->EntityFilter.matches(
                ~entity=row->(Utils.magic: 'entity => dict<EntityFilter.FieldValue.t>),
              )
            )
          | None => []
          }
          Promise.resolve(rows->(Utils.magic: array<'entity> => array<unknown>))
        })
      },
      ensureQueryIndexes: (~table: Table.table, ~filters) => {
        ensureQueryIndexesCalls
        ->Array.push({
          "tableName": table.tableName,
          "filters": filters,
        })
        ->ignore
        Promise.resolve()
      },
      ensureSchemaIndexes: (~entities as _) => Promise.resolve(),
      finalizeBackfill: (~entities, ~chainIds, ~readyAt) => {
        finalizeBackfillCalls
        ->Array.push({
          "entityNames": entities->Array.map((e: Internal.entityConfig) => e.name),
          "chainIds": chainIds,
          "readyAt": readyAt,
        })
        ->ignore
        Promise.resolve()
      },
      reset: () => JsError.throwWithMessage("Not implemented"),
      setChainMeta: _ => JsError.throwWithMessage("Not implemented"),
      pruneStaleCheckpoints: async (~safeCheckpointId as _) => (),
      pruneStaleEntityHistory: async (
        ~entityName as _,
        ~entityIndex as _,
        ~chainIdColumn as _,
        ~safeCheckpointId as _,
      ) => (),
      getRollbackTargetCheckpoint: (~reorgChainId as _, ~lastKnownValidBlockNumber as _) =>
        JsError.throwWithMessage("Not implemented"),
      getRollbackProgressDiff: (~scope as _, ~rollbackTargetCheckpointId as _) =>
        JsError.throwWithMessage("Not implemented"),
      getRollbackData: (~entityConfig as _, ~scope as _, ~rollbackTargetCheckpointId as _) =>
        JsError.throwWithMessage("Not implemented"),
      writeBatch: (
        ~batch as _,
        ~rollback as _,
        ~isInReorgThreshold as _,
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
    ...PgStorage.makePersistenceFromConfig(~config, ~storage=storageMock.storage),
    storageStatus: Ready({
      cleanRun: false,
      contractMapping: config.contractMapping,
      envioInfo: Some(JSON.Encode.object(Dict.make())),
      cache: Dict.make(),
      chains: [],
      reorgCheckpoints: [],
      checkpointId: 0n,
    }),
  }
}
