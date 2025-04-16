open Belt

type fieldValue

type t = {
  batcher: Batcher.t,
  loadEntitiesByIds: (
    array<Types.id>,
    ~entityMod: module(Entities.InternalEntity),
    ~logger: Pino.t=?,
  ) => promise<array<Entities.internalEntity>>,
  loadEntitiesByField: (
    ~operator: TableIndices.Operator.t,
    ~entityMod: module(Entities.InternalEntity),
    ~fieldName: string,
    ~fieldValue: fieldValue,
    ~fieldValueSchema: S.t<fieldValue>,
    ~logger: Pino.t=?,
  ) => promise<array<Entities.internalEntity>>,
}

let make = (~loadEntitiesByIds, ~loadEntitiesByField) => {
  {
    batcher: Batcher.make(),
    loadEntitiesByIds,
    loadEntitiesByField,
  }
}

// Ideally it shouldn't be here, but it'll make writing tests easier,
// until we have a proper mocking solution.
let makeWithDbConnection = () => {
  make(
    ~loadEntitiesByIds=(ids, ~entityMod, ~logger=?) =>
      DbFunctionsEntities.batchRead(~entityMod)(Db.sql, ids, ~logger?),
    ~loadEntitiesByField=DbFunctionsEntities.makeWhereQuery(Db.sql),
  )
}

let makeLoader = (
  type entity,
  loadLayer,
  ~entityMod: module(Entities.Entity with type t = entity),
  ~inMemoryStore,
  ~logger,
  ~groupLoad,
) => {
  let module(Entity) = entityMod
  let key = `${(Entity.name :> string)}.get`
  let entityMod = entityMod->Entities.entityModToInternal
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityMod)

  let load = async idsToLoad => {
    // Since makeLoader prevents registerign entities already existing in the inMemoryStore,
    // we can be sure that we load only the new ones.
    let dbEntities = await idsToLoad->loadLayer.loadEntitiesByIds(~entityMod, ~logger)

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

  loadLayer.batcher->Batcher.operation(
    ~key,
    ~load,
    ~group=groupLoad,
    ~hasher=Batcher.noopHasher,
    ~getUnsafeInMemory=inMemTable
    ->InMemoryTable.Entity.getUnsafe
    ->(Utils.magic: (string => option<Entities.internalEntity>) => string => option<entity>),
    ~hasInMemory=inMemTable->InMemoryTable.Entity.has,
  )
}

let makeWhereLoader = (
  type entity,
  loadLayer,
  ~operator: TableIndices.Operator.t,
  ~entityMod: module(Entities.Entity with type t = entity),
  ~inMemoryStore,
  ~logger,
  ~fieldName,
  ~fieldValueSchema,
  ~groupLoad,
) => {
  let module(Entity) = entityMod
  let key = `${(Entity.name :> string)}.getWhere.${fieldName}.${switch operator {
    | Eq => "eq"
    | Gt => "gt"
    }}`
  let entityMod = entityMod->Entities.entityModToInternal
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityMod)

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
          ~entityMod,
          ~fieldName=index->TableIndices.Index.getFieldName,
          ~fieldValue=switch index {
          | Single({fieldValue}) =>
            fieldValue->(Utils.magic: TableIndices.FieldValue.t => fieldValue)
          },
          ~fieldValueSchema=fieldValueSchema->(Utils.magic: S.t<'fieldValue> => S.t<fieldValue>),
          ~logger,
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

  loadLayer.batcher->Batcher.operation(
    ~key,
    ~load,
    ~group=groupLoad,
    ~hasher=fieldValue =>
      fieldValue->TableIndices.FieldValue.castFrom->TableIndices.FieldValue.toString,
    ~getUnsafeInMemory=inMemTable
    ->InMemoryTable.Entity.getUnsafeOnIndex(~fieldName, ~operator)
    ->(Utils.magic: (string => array<Entities.internalEntity>) => string => array<entity>),
    ~hasInMemory=inMemTable->InMemoryTable.Entity.hasIndex(~fieldName, ~operator),
  )
}
