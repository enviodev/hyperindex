open Belt

type fieldValue

type t = {
  loadManager: LoadManager.t,
  loadEntitiesByIds: (
    array<Types.id>,
    ~entityConfig: Internal.entityConfig,
    ~logger: Pino.t=?,
  ) => promise<array<Internal.entity>>,
  loadEntitiesByField: (
    ~operator: TableIndices.Operator.t,
    ~entityConfig: Internal.entityConfig,
    ~fieldName: string,
    ~fieldValue: fieldValue,
    ~fieldValueSchema: S.t<fieldValue>,
    ~logger: Pino.t=?,
  ) => promise<array<Internal.entity>>,
}

let make = (~loadEntitiesByIds, ~loadEntitiesByField) => {
  {
    loadManager: LoadManager.make(),
    loadEntitiesByIds,
    loadEntitiesByField,
  }
}

// Ideally it shouldn't be here, but it'll make writing tests easier,
// until we have a proper mocking solution.
let makeWithDbConnection = (~persistence=Config.codegenPersistence) => {
  let storage = Persistence.getInitializedStorageOrThrow(persistence)
  {
    loadManager: LoadManager.make(),
    loadEntitiesByIds: (ids, ~entityConfig, ~logger as _=?) =>
      storage.loadByIdsOrThrow(
        ~table=entityConfig.table,
        ~rowsSchema=entityConfig.rowsSchema,
        ~ids,
      ),
    loadEntitiesByField: DbFunctionsEntities.makeWhereQuery(Db.sql),
  }
}

let loadById = (
  loadLayer,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore,
  ~shouldGroup,
  ~eventItem,
  ~entityId,
) => {
  let key = `${entityConfig.name}.get`
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityConfig)

  let load = async idsToLoad => {
    // Since makeLoader prevents registerign entities already existing in the inMemoryStore,
    // we can be sure that we load only the new ones.
    let dbEntities = try {
      await idsToLoad->loadLayer.loadEntitiesByIds(
        ~entityConfig,
        ~logger=eventItem->Logging.getEventLogger,
      )
    } catch {
    | Persistence.StorageError({message, reason}) =>
      reason->ErrorHandling.mkLogAndRaise(~logger=eventItem->Logging.getEventLogger, ~msg=message)
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
  }

  loadLayer.loadManager->LoadManager.call(
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
  loadLayer,
  ~effect: Internal.effect,
  ~effectArgs,
  ~inMemoryStore,
  ~shouldGroup,
) => {
  let key = `${effect.name}.effect`
  let inMemTable = inMemoryStore->InMemoryStore.getEffectInMemTable(~effect)

  let load = args => {
    effect.callsCount = effect.callsCount + args->Array.length
    Prometheus.EffectCallsCount.set(~callsCount=effect.callsCount, ~effectName=effect.name)
    args
    ->Js.Array2.map(arg => {
      effect.handler(arg)->Promise.thenResolve(output => {
        inMemTable->InMemoryTable.setByHash(arg.cacheKey, output)
      })
    })
    ->Promise.all
    ->(Utils.magic: promise<array<unit>> => promise<unit>)
  }

  loadLayer.loadManager->LoadManager.call(
    ~key,
    ~load,
    ~shouldGroup,
    ~hasher=args => args.cacheKey,
    ~getUnsafeInMemory=hash => inMemTable->InMemoryTable.getUnsafeByHash(hash),
    ~hasInMemory=hash => inMemTable->InMemoryTable.hasByHash(hash),
    ~input=effectArgs,
  )
}

let loadByField = (
  loadLayer,
  ~operator: TableIndices.Operator.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore,
  ~fieldName,
  ~fieldValueSchema,
  ~shouldGroup,
  ~eventItem,
  ~fieldValue,
) => {
  let key = `${entityConfig.name}.getWhere.${fieldName}.${switch operator {
    | Eq => "eq"
    | Gt => "gt"
    }}`
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityConfig)

  let load = async (fieldValues: array<'fieldValue>) => {
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
        let entities = await loadLayer.loadEntitiesByField(
          ~operator=switch index {
          | Single({operator}) => operator
          },
          ~entityConfig,
          ~fieldName=index->TableIndices.Index.getFieldName,
          ~fieldValue=switch index {
          | Single({fieldValue}) =>
            fieldValue->(Utils.magic: TableIndices.FieldValue.t => fieldValue)
          },
          ~fieldValueSchema=fieldValueSchema->(Utils.magic: S.t<'fieldValue> => S.t<fieldValue>),
          ~logger=eventItem->Logging.getEventLogger,
        )

        entities->Array.forEach(entity => {
          //Set the entity in the in memory store
          inMemTable->InMemoryTable.Entity.initValue(
            ~allowOverWriteEntity=false,
            ~key=Entities.getEntityId(entity),
            ~entity=Some(entity),
          )
        })
      })
      ->Promise.all
  }

  loadLayer.loadManager->LoadManager.call(
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
