open Belt

module LoadActionMap = {
  type loadSingle<'entity> = {resolve: option<'entity> => unit}
  type loadMultiple<'entity> = {resolve: array<'entity> => unit}

  type fieldValue
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
  type t<'entity> = {
    singleEntities: dict<array<loadSingle<'entity>>>,
    lookupByIndex: dict<loadIndex<'entity>>,
  }
  let empty: unit => t<'entity> = () => {
    singleEntities: Js.Dict.empty(),
    lookupByIndex: Js.Dict.empty(),
  }
  let getSingleEntityIds = (map: t<'entity>) => map.singleEntities->Js.Dict.keys
  let getIndexes = (map: t<'entity>) => map.lookupByIndex->Js.Dict.values
  let entriesSingleEntities: t<'entity> => array<(key, array<loadSingle<'entity>>)> = map =>
    map.singleEntities->Js.Dict.entries

  let addSingle = (map: t<'entity>, ~entityId, ~resolve) => {
    let loadCallback: loadSingle<'entity> = {
      resolve: resolve,
    }
    switch map.singleEntities->Js.Dict.get(entityId) {
    | None => map.singleEntities->Js.Dict.set(entityId, [loadCallback])
    | Some(existingCallbacks) => existingCallbacks->Js.Array2.push(loadCallback)->ignore
    }
  }

  let addLookUpByIndex = (
    map: t<'entity>,
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

type t = dict<ref<LoadActionMap.t<Entities.internalEntity>>>

let make = (~config: Config.t) => {
  let maps = Js.Dict.empty()
  config.entities->Js.Array2.forEach(entityMod => {
    let module(Entity) = entityMod
    maps->Js.Dict.set(Entity.key, ref(LoadActionMap.empty()))
  })
  maps
}

type hasLoadActions = | @as(true) SomeLoadActions | @as(false) NoLoadActions
let toBool = hasLoadActions =>
  switch hasLoadActions {
  | SomeLoadActions => true
  | NoLoadActions => false
  }

let executeLoadActionMap = async (
  loadActionMapRef: ref<LoadActionMap.t<'entity>>,
  ~batchLoadIds: array<Types.id> => promise<array<'entity>>,
  ~whereFnComposer,
  ~inMemTable: InMemoryTable.Entity.t<'entity>,
) => {
  let loadActionMap = loadActionMapRef.contents

  let entityLoadIds = loadActionMap->LoadActionMap.getSingleEntityIds
  let lookupByIndex = loadActionMap->LoadActionMap.getIndexes

  //Only perform operations if there are any values
  switch (entityLoadIds, lookupByIndex) {
  | ([], []) =>
    //in this case there are no more load actions to be performed on this entity
    //for the given loader batch
    NoLoadActions
  | (entityLoadIds, lookupByIndex) =>
    loadActionMapRef := LoadActionMap.empty()

    let lookupIndexesNotInMemory = lookupByIndex->Array.keep(({index}) => {
      inMemTable->InMemoryTable.Entity.indexDoesNotExists(~index)
    })

    lookupIndexesNotInMemory->Array.forEach(({index}) => {
      inMemTable->InMemoryTable.Entity.addEmptyIndex(~index)
    })

    //Do not do these queries concurrently. They are cpu expensive for
    //postgres
    await lookupIndexesNotInMemory->Utils.awaitEach(async ({
      loadArgs: {fieldName, fieldValue, fieldValueSchema, ?logger},
    }) => {
      let entities = await whereFnComposer(~fieldName, ~fieldValue, ~fieldValueSchema, ~logger?)

      entities->Array.forEach(entity => {
        //Set the entity in the in memory store
        inMemTable->InMemoryTable.Entity.initValue(
          ~allowOverWriteEntity=false,
          ~key=Entities.getEntityIdUnsafe(entity),
          ~entity=Some(entity),
        )
      })
    })

    //filter out ids that don't already exist in the in memory store
    let idsNotInMemory =
      entityLoadIds->Array.keep(id => inMemTable->InMemoryTable.Entity.get(id)->Option.isNone)

    //load in values that don't exist in the inMemoryStore
    let res = await idsNotInMemory->batchLoadIds

    res->Array.forEach(entity => {
      //Set the entity in the in memory store
      inMemTable->InMemoryTable.Entity.initValue(
        ~allowOverWriteEntity=false,
        ~key=Entities.getEntityIdUnsafe(entity),
        ~entity=Some(entity),
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

    SomeLoadActions
  }
}

let makeLoader = (
  type entity,
  loadLayer,
  ~entityMod: module(Entities.Entity with type t = entity),
) => {
  let module(Entity) = entityMod
  let loadLayerRef = loadLayer->Js.Dict.unsafeGet(Entity.key)
  (entityId) => {
    Promise.make((resolve, _reject) => {
      loadLayerRef.contents->LoadActionMap.addSingle(~entityId, ~resolve)
    })->(Utils.magic: promise<option<Entities.internalEntity>> => promise<option<entity>>)
  }
}

let makeWhereEqLoader = (type entity, loadLayer, ~entityMod: module(Entities.Entity with type t = entity), ~fieldName, ~fieldValueSchema, ~logger) => {
  let module(Entity) = entityMod
  let loadLayerRef = loadLayer->Js.Dict.unsafeGet(Entity.key)
  fieldValue => {
    Promise.make((resolve, _reject) => {
      loadLayerRef.contents->LoadActionMap.addLookUpByIndex(
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

let executeLoadLayer = async (loadLayer, ~inMemoryStore: InMemoryStore.t, ~config: Config.t) => {
  let hasLoadActions = ref(true)

  while hasLoadActions.contents {
    let hasLoadActionsAll = await config.entities->Array.map(entityMod => {
      let module(Entity) = entityMod
      let loadLayerRef = loadLayer->Js.Dict.unsafeGet(Entity.key)
      loadLayerRef->executeLoadActionMap(
        ~inMemTable=inMemoryStore->InMemoryStore.getEntityTable(~entityMod),
        ~batchLoadIds=DbFunctionsEntities.batchRead(~entityMod)(DbFunctions.sql, _),
        ~whereFnComposer=DbFunctionsEntities.makeWhereEq(
          DbFunctions.sql,
          ~entityMod,
        ),
      )
    })->Promise.all

    hasLoadActions :=
      hasLoadActionsAll->Array.reduce(false, (accum, entityHasLoadActions) => {
        accum || entityHasLoadActions->toBool
      })
  }
}
