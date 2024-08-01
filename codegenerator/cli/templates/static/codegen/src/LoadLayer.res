open Belt

type fieldValue

module LoadActionMap = {
  type loadSingle = {
    resolve: option<Entities.internalEntity> => unit,
    reject: exn => unit,
    mutable promise: promise<option<Entities.internalEntity>>
  }
  type loadMultiple = {resolve: array<Entities.internalEntity> => unit}

  type loadArgs = {
    fieldName: string,
    fieldValue: fieldValue,
    fieldValueSchema: S.t<fieldValue>,
  }

  let makeLoadArgs = (
    ~fieldName,
    ~fieldValue: 'fieldValue,
    ~fieldValueSchema: RescriptSchema.S.t<'fieldValue>,
  ) => {
    fieldName,
    fieldValueSchema: Utils.magic(fieldValueSchema),
    fieldValue: Utils.magic(fieldValue),
  }

  type loadIndex = {
    index: TableIndices.Index.t,
    loadArgs,
    loadCallbacks: array<loadMultiple>,
  }

  type t = {
    byId: dict<loadSingle>,
    lookupByIndex: dict<loadIndex>,
    entityMod: module(Entities.InternalEntity),
    logger: Pino.t,
  }
  let make = (~entityMod, ~logger) => {
    byId: Js.Dict.empty(),
    lookupByIndex: Js.Dict.empty(),
    entityMod,
    logger,
  }
  let getIdsToLoad = (map: t) => map.byId->Js.Dict.keys
  let getIndexes = (map: t) => map.lookupByIndex->Js.Dict.values

  let registerLoadById = (map: t, ~entityId) => {
    switch map.byId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | Some(loadRecord) => loadRecord.promise
    | None => {
      let promise = Promise.make((resolve, reject) => {
        let loadRecord: loadSingle = {
          resolve,
          reject,
          promise: %raw(`null`)
        }
        map.byId->Js.Dict.set(entityId, loadRecord)
      })
      // Don't use ref, since it'll allocate an object to store .contents
      (map.byId->Js.Dict.unsafeGet(entityId)).promise = promise
      promise
    }
    }
  }

  let addLookUpByIndex = (map: t, ~index, ~resolve, ~fieldName, ~fieldValue, ~fieldValueSchema) => {
    let loadCallback: loadMultiple = {
      resolve: resolve,
    }
    let indexId = index->TableIndices.Index.toString
    switch map.lookupByIndex->Js.Dict.get(indexId) {
    | None =>
      map.lookupByIndex->Js.Dict.set(
        indexId,
        {
          index,
          loadArgs: makeLoadArgs(~fieldName, ~fieldValueSchema, ~fieldValue),
          loadCallbacks: [loadCallback],
        },
      )
    | Some({loadCallbacks}) => loadCallbacks->Js.Array2.push(loadCallback)->ignore
    }
  }
}

type rec t = {
  mutable byEntity: dict<LoadActionMap.t>,
  mutable isScheduled: bool,
  mutable inMemoryStore: InMemoryStore.t,
  loadEntitiesByIds: (
    array<Types.id>,
    ~entityMod: module(Entities.InternalEntity),
    ~logger: Pino.t=?,
  ) => promise<array<Entities.internalEntity>>,
  makeLoadEntitiesByField: (
    ~entityMod: module(Entities.InternalEntity),
  ) => (
    ~fieldName: string,
    ~fieldValue: fieldValue,
    ~fieldValueSchema: S.t<fieldValue>,
    ~logger: Pino.t=?,
  ) => promise<array<Entities.internalEntity>>,
}

let executeLoadEntitiesById = async (loadLayer, ~idsToLoad, ~loadActionMap: LoadActionMap.t) => {
  let {entityMod, logger} = loadActionMap

  try {
    let inMemTable = loadLayer.inMemoryStore->InMemoryStore.getEntityTable(~entityMod)

    // Since makeLoader prevents registerign entities already existing in the inMemTable,
    // we can be sure that we load only the new ones.
    let entities = await idsToLoad->loadLayer.loadEntitiesByIds(~entityMod, ~logger)

    let entitiesMap = Js.Dict.empty()
    for idx in 0 to entities->Array.length - 1 {
      let entity = entities->Js.Array2.unsafe_get(idx)
      entitiesMap->Js.Dict.set(entity->Entities.getEntityId, entity)
    }
    idsToLoad->Array.forEach(entityId => {
      //Set the entity in the in memory store
      inMemTable->InMemoryTable.Entity.initValue(
        ~allowOverWriteEntity=false,
        ~key=entityId,
        ~entity=entitiesMap->Js.Dict.get(entityId),
      )

      // Can use unsafeGet here safely since loadActionMap is snapshotted at the point and won't change
      let loadRecord = loadActionMap.byId->Js.Dict.unsafeGet(entityId)
      loadRecord.resolve(inMemTable->InMemoryTable.Entity.get(entityId)->Utils.Option.flatten)
    })
  } catch {
    | exn => {
      idsToLoad->Array.forEach(entityId => {
        // Can use unsafeGet here safely since loadActionMap is snapshotted at the point and won't change
        let loadRecord = loadActionMap.byId->Js.Dict.unsafeGet(entityId)
        loadRecord.reject(exn)
      })
    }
  }
}

let executeLoadEntitiesByIndex = async (loadLayer, ~lookupByIndex: array<LoadActionMap.loadIndex>, ~loadActionMap: LoadActionMap.t) => {
  let {entityMod, logger} = loadActionMap
  let inMemTable = loadLayer.inMemoryStore->InMemoryStore.getEntityTable(~entityMod)

  let lookupIndexesNotInMemory = lookupByIndex->Array.keep(({index}) => {
    inMemTable->InMemoryTable.Entity.indexDoesNotExists(~index)
  })

  lookupIndexesNotInMemory->Array.forEach(({index}) => {
    inMemTable->InMemoryTable.Entity.addEmptyIndex(~index)
  })

  let loadEntitiesByField = loadLayer.makeLoadEntitiesByField(~entityMod)
  //Do not do these queries concurrently. They are cpu expensive for
  //postgres
  await lookupIndexesNotInMemory->Utils.awaitEach(async ({
    loadArgs: {fieldName, fieldValue, fieldValueSchema},
  }) => {
    let entities = await loadEntitiesByField(
      ~fieldName,
      ~fieldValue,
      ~fieldValueSchema,
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

  loadActionMap
  ->LoadActionMap.getIndexes
  ->Array.forEach(({loadCallbacks, index}) => {
    let valuesOnIndex = inMemTable->InMemoryTable.Entity.getOnIndex(~index)
    loadCallbacks->Array.forEach(({resolve}) => {
      valuesOnIndex->resolve
    })
  })
}

let schedule = async loadLayer => {
  // Set the schedule function to None, to ensure that the logic runs only once until we finish executing.
  loadLayer.isScheduled = true

  // Use a while loop instead of a recursive function,
  // so the memory is grabaged collected between executions.
  // Although recursive function shouldn't have caused a memory leak,
  // there's still a chance for it living for a long time.
  while loadLayer.isScheduled {
    // Wait for a microtask here, to get all the actions registered in case when
    // running loaders in batch or using Promise.all
    // Theoretically, we could use a setTimeout, which would allow to skip awaits for
    // some context.<entitty>.get which are already in the in memory store.
    // This way we'd be able to register more actions,
    // but assuming it would not affect performance in a positive way.
    // On the other hand `await Promise.resolve()` is more predictable, easier for testing and less memory intensive.
    await Promise.resolve()

    let loadActionMaps = loadLayer.byEntity->Js.Dict.values

    // Reset loadActionMaps, so they can be filled with new loaders.
    // But don't reset the schedule function, so that it doesn't run before execute finishes.
    loadLayer.byEntity = Js.Dict.empty()

    let promises = []
    loadActionMaps->Array.forEach(loadActionMap => {
      switch loadActionMap->LoadActionMap.getIdsToLoad {
        | [] => ()
        | idsToLoad => 
          promises->Js.Array2.push(loadLayer->executeLoadEntitiesById(~idsToLoad, ~loadActionMap))->ignore
      }
      switch loadActionMap->LoadActionMap.getIndexes {
        | [] => ()
        | lookupByIndex => 
          promises->Js.Array2.push(loadLayer->executeLoadEntitiesByIndex(~lookupByIndex, ~loadActionMap))->ignore
      }
    })
    // Error should be caught for each loadActionMap execution separately, since we have a logger attached to it.
    let _: array<unit> = await promises->Promise.all

    // If there are new loaders register, schedule the next execution immediately.
    // Otherwise reset the schedule function, so it can be triggered externally again.
    if loadLayer.byEntity->Js.Dict.values->Array.length === 0 {
      loadLayer.isScheduled = false
    }
  }
}

let make = (~loadEntitiesByIds, ~makeLoadEntitiesByField) => {
  {
    byEntity: Js.Dict.empty(),
    isScheduled: false,
    inMemoryStore: InMemoryStore.make(),
    loadEntitiesByIds,
    makeLoadEntitiesByField,
  }
}

// Ideally it shouldn't be here, but it'll make writing tests easier,
// until we have a proper mocking solution.
let makeWithDbConnection = () => {
  make(
    ~loadEntitiesByIds=(ids, ~entityMod, ~logger=?) =>
      DbFunctionsEntities.batchRead(~entityMod)(DbFunctions.sql, ids, ~logger?),
    ~makeLoadEntitiesByField=(~entityMod) =>
      DbFunctionsEntities.makeWhereEq(DbFunctions.sql, ~entityMod),
  )
}

let setInMemoryStore = (loadLayer, ~inMemoryStore) => {
  loadLayer.inMemoryStore = inMemoryStore
}

let useActionMap = (loadLayer, ~entityMod: module(Entities.InternalEntity), ~logger) => {
  let module(Entity) = entityMod
  switch loadLayer.byEntity->Utils.Dict.dangerouslyGetNonOption(Entity.key) {
  | Some(loadActionMap) => loadActionMap
  | None => {
      let loadActionMap = LoadActionMap.make(~entityMod, ~logger)
      loadLayer.byEntity->Js.Dict.set(Entity.key, loadActionMap)
      if !loadLayer.isScheduled {
        let _: promise<()> = schedule(loadLayer)
      }
      loadActionMap
    }
  }
}

let makeLoader = (
  type entity,
  loadLayer,
  ~entityMod: module(Entities.Entity with type t = entity),
  ~logger,
) => {
  let module(Entity) = entityMod
  let entityMod = entityMod->Entities.entityModToInternal
  // Since makeLoader is called on every handler run, it's safe to get the inMemTable
  // outside of the returned function, since the inMemoryStore will always be up to date
  let inMemTable = loadLayer.inMemoryStore->InMemoryStore.getEntityTable(~entityMod)
  entityId => {
    switch inMemTable->InMemoryTable.Entity.get(entityId) {
    | Some(maybeEntity) => Promise.resolve(maybeEntity)
    | None =>
      loadLayer
        ->useActionMap(~entityMod, ~logger)
        ->LoadActionMap.registerLoadById(~entityId)
        ->(Utils.magic: promise<option<Entities.internalEntity>> => promise<option<entity>>)
    }
  }
}

let makeWhereEqLoader = (
  type entity,
  loadLayer,
  ~entityMod: module(Entities.Entity with type t = entity),
  ~logger,
  ~fieldName,
  ~fieldValueSchema,
) => {
  fieldValue => {
    Promise.make((resolve, _reject) => {
      loadLayer
      ->useActionMap(~entityMod=entityMod->Entities.entityModToInternal, ~logger)
      ->LoadActionMap.addLookUpByIndex(
        ~index=Single({
          fieldName,
          fieldValue: TableIndices.FieldValue.castFrom(fieldValue),
          operator: Eq,
        }),
        ~fieldValueSchema,
        ~fieldName,
        ~fieldValue,
        ~resolve,
      )
    })->(Utils.magic: promise<array<Entities.internalEntity>> => promise<array<entity>>)
  }
}
