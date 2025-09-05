open Belt

let loadById = (
  ~loadManager,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore,
  ~shouldGroup,
  ~item,
  ~entityId,
) => {
  let key = `${entityConfig.name}.get`
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityConfig)

  let load = async idsToLoad => {
    let timerRef = Prometheus.StorageLoad.startOperation(~operation=key)

    // Since LoadManager.call prevents registerign entities already existing in the inMemoryStore,
    // we can be sure that we load only the new ones.
    let dbEntities = try {
      await (persistence->Persistence.getInitializedStorageOrThrow).loadByIdsOrThrow(
        ~table=entityConfig.table,
        ~rowsSchema=entityConfig.rowsSchema,
        ~ids=idsToLoad,
      )
    } catch {
    | Persistence.StorageError({message, reason}) =>
      reason->ErrorHandling.mkLogAndRaise(~logger=item->Logging.getItemLogger, ~msg=message)
    }

    let entitiesMap = Js.Dict.empty()
    for idx in 0 to dbEntities->Array.length - 1 {
      let entity = dbEntities->Js.Array2.unsafe_get(idx)
      entitiesMap->Js.Dict.set(entity.id, entity)
    }
    idsToLoad->Js.Array2.forEach(entityId => {
      // Set the entity in the in memory store
      // without overwriting existing values
      // which might be newer than what we got from db
      inMemTable->InMemoryTable.Entity.initValue(
        ~allowOverWriteEntity=false,
        ~key=entityId,
        ~entity=entitiesMap->Utils.Dict.dangerouslyGetNonOption(entityId),
      )
    })

    timerRef->Prometheus.StorageLoad.endOperation(
      ~operation=key,
      ~whereSize=idsToLoad->Array.length,
      ~size=dbEntities->Array.length,
    )
  }

  loadManager->LoadManager.call(
    ~key,
    ~load,
    ~shouldGroup,
    ~hasher=LoadManager.noopHasher,
    ~getUnsafeInMemory=inMemTable->InMemoryTable.Entity.getUnsafe,
    ~hasInMemory=hash => inMemTable.table->InMemoryTable.hasByHash(hash),
    ~input=entityId,
  )
}

let loadEffect = (
  ~loadManager,
  ~persistence: Persistence.t,
  ~effect: Internal.effect,
  ~effectArgs,
  ~inMemoryStore,
  ~shouldGroup,
  ~item,
) => {
  let key = `${effect.name}.effect`
  let inMemTable = inMemoryStore->InMemoryStore.getEffectInMemTable(~effect)

  let load = async args => {
    let idsToLoad = args->Js.Array2.map((arg: Internal.effectArgs) => arg.cacheKey)
    let idsFromCache = Utils.Set.make()

    switch effect.cache {
    | Some({table, rowsSchema})
      if switch persistence.storageStatus {
      | Ready({cache}) => cache->Utils.Dict.has(effect.name)
      | _ => false
      } => {
        let dbEntities = try {
          await (persistence->Persistence.getInitializedStorageOrThrow).loadByIdsOrThrow(
            ~table,
            ~rowsSchema,
            ~ids=idsToLoad,
          )
        } catch {
        | Persistence.StorageError({message, reason}) =>
          reason->ErrorHandling.mkLogAndRaise(
            ~logger=item->Logging.getItemLogger,
            ~msg=message,
          )
        }

        dbEntities->Js.Array2.forEach(entity => {
          idsFromCache->Utils.Set.add(entity.id)->ignore
          inMemTable.dict->Js.Dict.set(entity.id, entity.output)
        })
      }
    | _ => ()
    }

    let remainingCallsCount = idsToLoad->Array.length - idsFromCache->Utils.Set.size
    if remainingCallsCount > 0 {
      effect.callsCount = effect.callsCount + remainingCallsCount
      Prometheus.EffectCallsCount.set(~callsCount=effect.callsCount, ~effectName=effect.name)

      let shouldStoreCache = effect.cache->Option.isSome
      let ids = []

      args
      ->Belt.Array.keepMapU((arg: Internal.effectArgs) => {
        if idsFromCache->Utils.Set.has(arg.cacheKey) {
          None
        } else {
          ids->Array.push(arg.cacheKey)->ignore
          Some(
            effect.handler(arg)->Promise.thenResolve(output => {
              inMemTable.dict->Js.Dict.set(arg.cacheKey, output)
              if shouldStoreCache {
                inMemTable.idsToStore->Array.push(arg.cacheKey)->ignore
              }
            }),
          )
        }
      })
      ->Promise.all
      ->(Utils.magic: promise<array<unit>> => unit)
    }
  }

  loadManager->LoadManager.call(
    ~key,
    ~load,
    ~shouldGroup,
    ~hasher=args => args.cacheKey,
    ~getUnsafeInMemory=hash => inMemTable.dict->Js.Dict.unsafeGet(hash),
    ~hasInMemory=hash => inMemTable.dict->Utils.Dict.has(hash),
    ~input=effectArgs,
  )
}

let loadByField = (
  ~loadManager,
  ~persistence: Persistence.t,
  ~operator: TableIndices.Operator.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore,
  ~fieldName,
  ~fieldValueSchema,
  ~shouldGroup,
  ~item,
  ~fieldValue,
) => {
  let operatorCallName = switch operator {
  | Eq => "eq"
  | Gt => "gt"
  }
  let key = `${entityConfig.name}.getWhere.${fieldName}.${operatorCallName}`
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityConfig)

  let load = async (fieldValues: array<'fieldValue>) => {
    let timerRef = Prometheus.StorageLoad.startOperation(~operation=key)

    let size = ref(0)

    let indiciesToLoad = fieldValues->Js.Array2.map((fieldValue): TableIndices.Index.t => {
      Single({
        fieldName,
        fieldValue: TableIndices.FieldValue.castFrom(fieldValue),
        operator,
      })
    })

    let _ =
      await indiciesToLoad
      ->Js.Array2.map(async index => {
        inMemTable->InMemoryTable.Entity.addEmptyIndex(~index)
        let entities = try {
          await (persistence->Persistence.getInitializedStorageOrThrow).loadByFieldOrThrow(
            ~operator=switch index {
            | Single({operator: Gt}) => #">"
            | Single({operator: Eq}) => #"="
            },
            ~table=entityConfig.table,
            ~rowsSchema=entityConfig.rowsSchema,
            ~fieldName=index->TableIndices.Index.getFieldName,
            ~fieldValue=switch index {
            | Single({fieldValue}) => fieldValue
            },
            ~fieldSchema=fieldValueSchema->(
              Utils.magic: S.t<'fieldValue> => S.t<TableIndices.FieldValue.t>
            ),
          )
        } catch {
        | Persistence.StorageError({message, reason}) =>
          reason->ErrorHandling.mkLogAndRaise(
            ~logger=Logging.createChildFrom(
              ~logger=item->Logging.getItemLogger,
              ~params={
                "operator": operatorCallName,
                "tableName": entityConfig.table.tableName,
                "fieldName": fieldName,
                "fieldValue": fieldValue,
              },
            ),
            ~msg=message,
          )
        }

        entities->Array.forEach(entity => {
          //Set the entity in the in memory store
          inMemTable->InMemoryTable.Entity.initValue(
            ~allowOverWriteEntity=false,
            ~key=Entities.getEntityId(entity),
            ~entity=Some(entity),
          )
        })

        size := size.contents + entities->Array.length
      })
      ->Promise.all

    timerRef->Prometheus.StorageLoad.endOperation(
      ~operation=key,
      ~whereSize=fieldValues->Array.length,
      ~size=size.contents,
    )
  }

  loadManager->LoadManager.call(
    ~key,
    ~load,
    ~input=fieldValue,
    ~shouldGroup,
    ~hasher=fieldValue =>
      fieldValue->TableIndices.FieldValue.castFrom->TableIndices.FieldValue.toString,
    ~getUnsafeInMemory=inMemTable->InMemoryTable.Entity.getUnsafeOnIndex(~fieldName, ~operator),
    ~hasInMemory=inMemTable->InMemoryTable.Entity.hasIndex(~fieldName, ~operator),
  )
}
