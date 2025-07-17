module InMemoryStore = {
  let setEntity = (inMemoryStore, ~entityMod, entity) => {
    let inMemTable =
      inMemoryStore->InMemoryStore.getInMemTable(
        ~entityConfig=entityMod->Entities.entityModToInternal,
      )
    let entity = entity->(Utils.magic: 'a => Entities.internalEntity)
    inMemTable->InMemoryTable.Entity.set(
      Set(entity)->Types.mkEntityUpdate(
        ~eventIdentifier={
          chainId: 0,
          blockTimestamp: 0,
          blockNumber: 0,
          logIndex: 0,
        },
        ~entityId=entity->Entities.getEntityId,
      ),
      ~shouldSaveHistory=RegisterHandlers.getConfig()->Config.shouldSaveHistory(
        ~isInReorgThreshold=false,
      ),
    )
  }

  let make = (~entities=[]) => {
    let inMemoryStore = InMemoryStore.make()
    entities->Js.Array2.forEach(((entityMod, items)) => {
      items->Js.Array2.forEach(entity => {
        inMemoryStore->setEntity(~entityMod, entity)
      })
    })
    inMemoryStore
  }
}

module Storage = {
  type method = [
    | #isInitialized
    | #initialize
    | #dumpEffectCache
    | #restoreEffectCache
    | #setEffectCacheOrThrow
    | #loadByIdsOrThrow
    | #loadByFieldOrThrow
    | #setOrThrow
  ]

  type t = {
    isInitializedCalls: array<bool>,
    resolveIsInitialized: bool => unit,
    initializeCalls: array<{
      "entities": array<Internal.entityConfig>,
      "generalTables": array<Table.table>,
      "enums": array<Internal.enumConfig<Internal.enum>>,
    }>,
    resolveInitialize: unit => unit,
    loadByIdsOrThrowCalls: array<{"ids": array<string>, "tableName": string}>,
    loadByFieldOrThrowCalls: array<{
      "fieldName": string,
      "fieldValue": unknown,
      "tableName": string,
      "operator": Persistence.operator,
    }>,
    dumpEffectCacheCalls: ref<int>,
    restoreEffectCacheCalls: array<{"withUpload": bool}>,
    storage: Persistence.storage,
  }

  let make = (methods: array<method>) => {
    let implement = (method: method, fn) => {
      if methods->Js.Array2.includes(method) {
        fn
      } else {
        (() => Js.Exn.raiseError(`storage.${(method :> string)} not implemented`))->Obj.magic
      }
    }

    let implementBody = (method: method, fn) => {
      if methods->Js.Array2.includes(method) {
        fn()
      } else {
        Js.Exn.raiseError(`storage.${(method :> string)} not implemented`)
      }
    }

    let isInitializedCalls = []
    let initializeCalls = []
    let isInitializedResolveFns = []
    let initializeResolveFns = []
    let loadByIdsOrThrowCalls = []
    let loadByFieldOrThrowCalls = []
    let dumpEffectCacheCalls = ref(0)
    let restoreEffectCacheCalls = []
    let setEffectCacheOrThrowCalls = ref(0)

    {
      isInitializedCalls,
      initializeCalls,
      loadByIdsOrThrowCalls,
      loadByFieldOrThrowCalls,
      dumpEffectCacheCalls,
      restoreEffectCacheCalls,
      resolveIsInitialized: bool => {
        isInitializedResolveFns->Js.Array2.forEach(resolve => resolve(bool))
      },
      resolveInitialize: () => {
        initializeResolveFns->Js.Array2.forEach(resolve => resolve())
      },
      storage: {
        isInitialized: implement(#isInitialized, () => {
          isInitializedCalls->Js.Array2.push(true)->ignore
          Promise.make((resolve, _reject) => {
            isInitializedResolveFns->Js.Array2.push(resolve)->ignore
          })
        }),
        initialize: implement(#initialize, (~entities=[], ~generalTables=[], ~enums=[]) => {
          initializeCalls
          ->Js.Array2.push({
            "entities": entities,
            "generalTables": generalTables,
            "enums": enums,
          })
          ->ignore
          Promise.make((resolve, _reject) => {
            initializeResolveFns->Js.Array2.push(resolve)->ignore
          })
        }),
        dumpEffectCache: implement(#dumpEffectCache, () => {
          dumpEffectCacheCalls := dumpEffectCacheCalls.contents + 1
          Promise.resolve()
        }),
        restoreEffectCache: implement(#restoreEffectCache, (~withUpload) => {
          restoreEffectCacheCalls->Js.Array2.push({"withUpload": withUpload})->ignore
          Promise.resolve([])
        }),
        setEffectCacheOrThrow: implement(#setEffectCacheOrThrow, (
          ~effectName as _,
          ~ids as _,
          ~outputs as _,
          ~outputSchema as _,
          ~initialize as _,
        ) => {
          setEffectCacheOrThrowCalls := setEffectCacheOrThrowCalls.contents + 1
          Promise.resolve()
        }),
        loadByIdsOrThrow: (
          type item,
          ~ids,
          ~table: Table.table,
          ~rowsSchema as _: S.t<array<item>>,
        ): promise<array<item>> => {
          implementBody(#loadByIdsOrThrow, () => {
            loadByIdsOrThrowCalls
            ->Js.Array2.push({
              "ids": ids,
              "tableName": table.tableName,
            })
            ->ignore
            Promise.resolve([])
          })
        },
        loadByFieldOrThrow: (
          ~fieldName,
          ~fieldSchema as _,
          ~fieldValue,
          ~operator,
          ~table: Table.table,
          ~rowsSchema as _,
        ) => {
          implementBody(#loadByFieldOrThrow, () => {
            loadByFieldOrThrowCalls
            ->Js.Array2.push({
              "fieldName": fieldName,
              "fieldValue": fieldValue->Utils.magic,
              "tableName": table.tableName,
              "operator": operator,
            })
            ->ignore
            Promise.resolve([])
          })
        },
        setOrThrow: (~items as _, ~table as _, ~itemSchema as _) => {
          implementBody(#setOrThrow, () => Js.Exn.raiseError("Not implemented"))
        },
      },
    }
  }

  let toPersistence = (storageMock: t) => {
    {
      ...Config.codegenPersistence,
      storage: storageMock.storage,
      storageStatus: Ready({
        cleanRun: false,
        cache: Js.Dict.empty(),
      }),
    }
  }
}

@genType
let mockRawEventRow: TablesStatic.RawEvents.t = {
  chainId: 1,
  eventId: 1234567890n,
  contractName: "NftFactory",
  eventName: "SimpleNftCreated",
  blockNumber: 1000,
  logIndex: 10,
  transactionFields: S.reverseConvertToJsonOrThrow(
    {
      Types.Transaction.transactionIndex: 20,
      hash: "0x1234567890abcdef",
    },
    Types.Transaction.schema,
  ),
  srcAddress: "0x0123456789abcdef0123456789abcdef0123456"->Utils.magic,
  blockHash: "0x9876543210fedcba9876543210fedcba987654321",
  blockTimestamp: 1620720000,
  blockFields: %raw(`{}`),
  params: {
    "foo": "bar",
    "baz": 42,
  }->Utils.magic,
}

let eventId = "0xcf16a92280c1bbb43f72d31126b724d508df2877835849e8744017ab36a9b47f_1"

let evmEventConfig = (
  ~id=eventId,
  ~contractName="ERC20",
  ~blockSchema: option<S.t<'block>>=?,
  ~transactionSchema: option<S.t<'transaction>>=?,
  ~isWildcard=false,
  ~dependsOnAddresses=?,
  ~filterByAddresses=false,
): Internal.evmEventConfig => {
  {
    id,
    contractName,
    name: "EventWithoutFields",
    isWildcard,
    filterByAddresses,
    dependsOnAddresses: filterByAddresses ||
    dependsOnAddresses->Belt.Option.getWithDefault(!isWildcard),
    loader: None,
    handler: None,
    contractRegister: None,
    paramsRawEventSchema: S.literal(%raw(`null`))
    ->S.shape(_ => ())
    ->(Utils.magic: S.t<unit> => S.t<Internal.eventParams>),
    blockSchema: blockSchema
    ->Belt.Option.getWithDefault(S.object(_ => ())->Utils.magic)
    ->Utils.magic,
    transactionSchema: transactionSchema
    ->Belt.Option.getWithDefault(S.object(_ => ())->Utils.magic)
    ->Utils.magic,
    getEventFiltersOrThrow: _ =>
      switch dependsOnAddresses {
      | Some(true) =>
        Dynamic(
          addresses => [
            {
              topic0: [
                // This is a sighash in the original code
                id->EvmTypes.Hex.fromStringUnsafe,
              ],
              topic1: addresses->Utils.magic,
              topic2: [],
              topic3: [],
            },
          ],
        )
      | _ =>
        Static([
          {
            topic0: [
              // This is a sighash in the original code
              id->EvmTypes.Hex.fromStringUnsafe,
            ],
            topic1: [],
            topic2: [],
            topic3: [],
          },
        ])
      },
    convertHyperSyncEventArgs: _ => Js.Exn.raiseError("Not implemented"),
  }
}
