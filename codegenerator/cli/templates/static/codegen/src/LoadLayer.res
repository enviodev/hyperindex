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
) => {
  let module(Entity) = entityMod
  let operationKey = `${(Entity.name :> string)}.get`
  let entityMod = entityMod->Entities.entityModToInternal
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityMod)

  let operation = async idsToLoad => {
    // Since makeLoader prevents registerign entities already existing in the inMemoryStore,
    // we can be sure that we load only the new ones.
    let dbEntities = await idsToLoad->loadLayer.loadEntitiesByIds(~entityMod, ~logger)

    let entitiesMap = Js.Dict.empty()
    for idx in 0 to dbEntities->Array.length - 1 {
      let entity = dbEntities->Js.Array2.unsafe_get(idx)
      entitiesMap->Js.Dict.set(entity.id, entity)
    }
    idsToLoad->Js.Array2.map(entityId => {
      // Set the entity in the in memory store
      // without overwriting existing values
      // which might be newer than what we got from db
      inMemTable->InMemoryTable.Entity.initValue(
        ~allowOverWriteEntity=false,
        ~key=entityId,
        ~entity=entitiesMap->Utils.Dict.dangerouslyGetNonOption(entityId),
      )

      // For the same reason as above
      // get an entity from in-memory store
      // since it might be newer than the one from DB
      inMemTable->InMemoryTable.Entity.get(entityId)->Utils.Option.flatten
    })
  }

  entityId => {
    switch inMemTable->InMemoryTable.Entity.get(entityId) {
    | Some(maybeEntity) => Promise.resolve(maybeEntity)
    | None =>
      loadLayer.batcher->Batcher.call(
        ~operationKey,
        ~operation,
        ~inputKey=entityId,
        ~input=entityId,
      )
    }->(Utils.magic: promise<option<Entities.internalEntity>> => promise<option<entity>>)
  }
}

let makeWhereLoader = (
  type entity,
  loadLayer,
  ~operator,
  ~entityMod: module(Entities.Entity with type t = entity),
  ~inMemoryStore,
  ~logger,
  ~fieldName,
  ~fieldValueSchema,
) => {
  let module(Entity) = entityMod
  let operationKey = `${(Entity.name :> string)}.getWhere`
  let entityMod = entityMod->Entities.entityModToInternal
  let inMemTable = inMemoryStore->InMemoryStore.getInMemTable(~entityMod)

  let operation = async (indiciesToLoad: array<TableIndices.Index.t>) => {
    // TODO: Maybe worth moving the check before the place where we register the load in a batchQueue
    // Need to duble check that it won't resolve an empty index
    let lookupIndexesNotInMemory = indiciesToLoad->Array.keep(index => {
      let notInMemory = inMemTable->InMemoryTable.Entity.indexDoesNotExists(~index)
      if notInMemory {
        inMemTable->InMemoryTable.Entity.addEmptyIndex(~index)
      }
      notInMemory
    })

    //Do not do these queries concurrently. They are cpu expensive for
    //postgres
    await lookupIndexesNotInMemory->Utils.Array.awaitEach(async index => {
      let entities = await loadLayer.loadEntitiesByField(
        ~operator=switch index {
        | Single({operator}) => operator
        },
        ~entityMod,
        ~fieldName=index->TableIndices.Index.getFieldName,
        ~fieldValue=switch index {
        | Single({fieldValue}) => fieldValue->(Utils.magic: TableIndices.FieldValue.t => fieldValue)
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

    indiciesToLoad->Array.map(index => {
      inMemTable->InMemoryTable.Entity.getOnIndex(~index)
    })
  }

  (fieldValue: 'fieldValue) => {
    let index: TableIndices.Index.t = Single({
      fieldName,
      fieldValue: TableIndices.FieldValue.castFrom(fieldValue),
      operator,
    })
    loadLayer.batcher
    ->Batcher.call(
      ~operationKey,
      ~operation,
      ~inputKey=index->TableIndices.Index.toString,
      ~input=index,
    )
    ->(Utils.magic: promise<array<Entities.internalEntity>> => promise<array<entity>>)
  }
}
