open Belt

type fieldValue

module LoadActionMap = {
  type loadSingle<'entity> = {resolve: option<'entity> => unit}
  type loadMultiple<'entity> = {resolve: array<'entity> => unit}

  type loadArgs<'entity> = {
    fieldName: string,
    fieldValue: fieldValue,
    fieldValueSchema: S.t<fieldValue>,
    logger?: Pino.t,
  }

  let makeLoadArgs = (
    ~fieldName,
    ~fieldValue: 'fieldValue,
    ~fieldValueSchema: RescriptSchema.S.t<'fieldValue>,
    ~logger,
  ) => {
    fieldName,
    fieldValueSchema: Utils.magic(fieldValueSchema),
    logger,
    fieldValue: Utils.magic(fieldValue),
  }

  type loadIndex<'entity> = {
    index: TableIndices.Index.t,
    loadArgs: loadArgs<'entity>,
    loadCallbacks: array<loadMultiple<'entity>>,
  }

  type key = string
  type t = {
    singleEntities: dict<array<loadSingle<Entities.internalEntity>>>,
    lookupByIndex: dict<loadIndex<Entities.internalEntity>>,
    entityMod: module(Entities.InternalEntity),
  }
  let make = (~entityMod) => {
    singleEntities: Js.Dict.empty(),
    lookupByIndex: Js.Dict.empty(),
    entityMod,
  }
  let getSingleEntityIds = (map: t) => map.singleEntities->Js.Dict.keys
  let getIndexes = (map: t) => map.lookupByIndex->Js.Dict.values
  let entriesSingleEntities: t => array<(key, array<loadSingle<'entity>>)> = map =>
    map.singleEntities->Js.Dict.entries

  let addSingle = (map: t, ~entityId, ~resolve) => {
    let loadCallback: loadSingle<'entity> = {
      resolve: resolve,
    }
    switch map.singleEntities->Js.Dict.get(entityId) {
    | None => map.singleEntities->Js.Dict.set(entityId, [loadCallback])
    | Some(existingCallbacks) => existingCallbacks->Js.Array2.push(loadCallback)->ignore
    }
  }

  let addLookUpByIndex = (
    map: t,
    ~index,
    ~resolve,
    ~fieldName,
    ~fieldValue,
    ~fieldValueSchema,
    ~logger,
  ) => {
    let loadCallback: loadMultiple<'entity> = {
      resolve: resolve,
    }
    let indexId = index->TableIndices.Index.toString
    switch map.lookupByIndex->Js.Dict.get(indexId) {
    | None =>
      map.lookupByIndex->Js.Dict.set(
        indexId,
        {
          index,
          loadArgs: makeLoadArgs(~fieldName, ~fieldValueSchema, ~fieldValue, ~logger),
          loadCallbacks: [loadCallback],
        },
      )
    | Some({loadCallbacks}) => loadCallbacks->Js.Array2.push(loadCallback)->ignore
    }
  }
}

type rec t = {
  mutable byEntity: dict<LoadActionMap.t>,
  mutable schedule: option<t => unit>,
  mutable inMemoryStore: InMemoryStore.t,
  loadEntitiesByIds: (
    array<Types.id>,
    ~entityMod: module(Entities.InternalEntity),
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

let executeLoadActionMap = async (loadLayer, ~loadActionMap: LoadActionMap.t) => {
  let entityLoadIds = loadActionMap->LoadActionMap.getSingleEntityIds
  let lookupByIndex = loadActionMap->LoadActionMap.getIndexes

  //Only perform operations if there are any values
  switch (entityLoadIds, lookupByIndex) {
  | ([], []) => //in this case there are no more load actions to be performed on this entity
    //for the given loader batch
    ()
  | (entityIdsToLoad, lookupByIndex) =>
    let {entityMod} = loadActionMap
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
      loadArgs: {fieldName, fieldValue, fieldValueSchema, ?logger},
    }) => {
      let entities = await loadEntitiesByField(~fieldName, ~fieldValue, ~fieldValueSchema, ~logger?)

      entities->Array.forEach(entity => {
        //Set the entity in the in memory store
        inMemTable->InMemoryTable.Entity.initValue(
          ~allowOverWriteEntity=false,
          ~key=Entities.getEntityId(entity),
          ~entity=Some(entity),
        )
      })
    })

    // Since makeLoader prevents registerign entities already existing in the inMemTable,
    // we can be sure that we load only the new ones.
    let entities = await entityIdsToLoad->loadLayer.loadEntitiesByIds(~entityMod)
    let entitiesMap = Js.Dict.empty()
    for idx in 0 to entities->Array.length - 1 {
      let entity = entities->Js.Array2.unsafe_get(idx)
      entitiesMap->Js.Dict.set(entity->Entities.getEntityId, entity)
    }
    entityIdsToLoad->Array.forEach(entityId => {
      //Set the entity in the in memory store
      inMemTable->InMemoryTable.Entity.initValue(
        ~allowOverWriteEntity=false,
        ~key=entityId,
        ~entity=entitiesMap->Js.Dict.get(entityId),
      )
    })

    //Iterate through the map and resolve the load actions for each entity
    loadActionMap
    ->LoadActionMap.entriesSingleEntities
    ->Array.forEach(((entityId, loadActions)) => {
      loadActions->Array.forEach(({resolve}) => {
        resolve(inMemTable->InMemoryTable.Entity.get(entityId)->Utils.Option.flatten)
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
}

let execute = (loadLayer, ~loadActionMaps: array<LoadActionMap.t>) => {
  loadActionMaps
  ->Array.map(loadActionMap => {
    loadLayer->executeLoadActionMap(~loadActionMap)
  })
  ->Promise.all
}

let rec schedule = loadLayer => {
  // Set the schedule function to None, to ensure that the logic runs only once until we finish executing.
  loadLayer.schedule = None

  // FIXME: Maybe that's not what we want to do here.
  // We wait a macrotask here, to wait until all promises are resolved.
  // Theoretically, we could use a microtask. But in this case loading an entity,
  // which already exists in the in memory store,
  // would require to wait until we do a round trip to the database.
  let _ = Js.Global.setTimeout(() => {
    let loadActionMaps = loadLayer.byEntity->Js.Dict.values

    // Reset loadActionMaps, so they can be filled with new loaders.
    // But don't reset the schedule function, so that it doesn't run before execute finishes.
    loadLayer.byEntity = Js.Dict.empty()

    let _ =
      loadLayer
      ->execute(~loadActionMaps)
      ->Promise.thenResolve(_ => {
        // If there are new loaders register, schedule the next execution immediately.
        // Otherwise reset the schedule function, so it can be triggered externally again.
        if loadLayer.byEntity->Js.Dict.values->Array.length > 0 {
          schedule(loadLayer)
        } else {
          loadLayer.schedule = Some(schedule)
        }
      })
  }, 0)
}

let make = (~loadEntitiesByIds, ~makeLoadEntitiesByField) => {
  {
    byEntity: Js.Dict.empty(),
    schedule: Some(schedule),
    inMemoryStore: InMemoryStore.make(),
    loadEntitiesByIds,
    makeLoadEntitiesByField,
  }
}

let setInMemoryStore = (loadLayer, ~inMemoryStore) => {
  loadLayer.inMemoryStore = inMemoryStore
}

let useActionMap = (loadLayer, ~entityMod: module(Entities.InternalEntity)) => {
  let module(Entity) = entityMod
  switch loadLayer.byEntity->Utils.Dict.dangerouslyGetNonOption(Entity.key) {
  | Some(loadActionMap) => loadActionMap
  | None => {
      let loadActionMap = LoadActionMap.make(~entityMod)
      loadLayer.byEntity->Js.Dict.set(Entity.key, loadActionMap)
      switch loadLayer.schedule {
      | None => ()
      | Some(schedule) => schedule(loadLayer)
      }
      loadActionMap
    }
  }
}

let makeLoader = (
  type entity,
  loadLayer,
  ~entityMod: module(Entities.Entity with type t = entity),
) => {
  let module(Entity) = entityMod
  let entityMod = entityMod->Entities.entityModToInternal
  // Since makeLoader is called on every handler run, it's safe to get the inMemTable
  // outside of the returned function, since the inMemoryStore will always be up to date
  let inMemTable = loadLayer.inMemoryStore->InMemoryStore.getEntityTable(~entityMod)
  entityId => {
    switch inMemTable->InMemoryTable.Entity.get(entityId) {
      | Some(maybeEntity) => Promise.resolve(maybeEntity)
      | None => Promise.make((resolve, _reject) => {
        loadLayer
        ->useActionMap(~entityMod)
        ->LoadActionMap.addSingle(~entityId, ~resolve)
      })->(Utils.magic: promise<option<Entities.internalEntity>> => promise<option<entity>>)
    }
  }
}

let makeWhereEqLoader = (
  type entity,
  loadLayer,
  ~entityMod: module(Entities.Entity with type t = entity),
  ~fieldName,
  ~fieldValueSchema,
  ~logger,
) => {
  fieldValue => {
    Promise.make((resolve, _reject) => {
      loadLayer
      ->useActionMap(~entityMod=entityMod->Entities.entityModToInternal)
      ->LoadActionMap.addLookUpByIndex(
        ~index=Single({
          fieldName,
          fieldValue: TableIndices.FieldValue.castFrom(fieldValue),
          operator: Eq,
        }),
        ~fieldValueSchema,
        ~logger,
        ~fieldName,
        ~fieldValue,
        ~resolve,
      )
    })->(Utils.magic: promise<array<Entities.internalEntity>> => promise<array<entity>>)
  }
}
