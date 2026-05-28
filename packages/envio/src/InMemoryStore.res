type rawEventsKey = {
  chainId: int,
  eventId: string,
}

let hashRawEventsKey = (key: rawEventsKey) =>
  EventUtils.getEventIdKeyString(~chainId=key.chainId, ~eventId=key.eventId)

module EntityTables = {
  type t = dict<InMemoryTable.Entity.t>
  exception UndefinedEntity({entityName: string})
  let make = (entities: array<Internal.entityConfig>): t => {
    let init = Dict.make()
    entities->Belt.Array.forEach(entityConfig => {
      init->Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
    })
    init
  }

  let get = (self: t, ~entityName: string) => {
    switch self->Utils.Dict.dangerouslyGetNonOption(entityName) {
    | Some(table) => table
    | None =>
      UndefinedEntity({entityName: entityName})->ErrorHandling.mkLogAndRaise(
        ~msg="Unexpected, entity InMemoryTable is undefined",
      )
    }
  }
}

type effectCacheInMemTable = {
  idsToStore: array<string>,
  mutable invalidationsCount: int,
  dict: dict<Internal.effectOutput>,
  effect: Internal.effect,
}

type t = {
  allEntities: array<Internal.entityConfig>,
  mutable rawEvents: InMemoryTable.t<rawEventsKey, InternalTable.RawEvents.t>,
  mutable entities: dict<InMemoryTable.Entity.t>,
  mutable effects: dict<effectCacheInMemTable>,
  mutable rollbackTargetCheckpointId: option<Internal.checkpointId>,
}

let make = (~entities: array<Internal.entityConfig>, ~rollbackTargetCheckpointId=?): t => {
  allEntities: entities,
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  effects: Dict.make(),
  rollbackTargetCheckpointId,
}

let clear = (self: t) => {
  self.rawEvents = InMemoryTable.make(~hash=hashRawEventsKey)
  self.entities = EntityTables.make(self.allEntities)
  self.effects = Dict.make()
  self.rollbackTargetCheckpointId = None
}

let getEffectInMemTable = (inMemoryStore: t, ~effect: Internal.effect) => {
  let key = effect.name
  switch inMemoryStore.effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table = {
      idsToStore: [],
      dict: Dict.make(),
      invalidationsCount: 0,
      effect,
    }
    inMemoryStore.effects->Dict.set(key, table)
    table
  }
}

let getInMemTable = (
  inMemoryStore: t,
  ~entityConfig: Internal.entityConfig,
): InMemoryTable.Entity.t => {
  inMemoryStore.entities->EntityTables.get(~entityName=entityConfig.name)
}

let isRollingBack = (inMemoryStore: t) => inMemoryStore.rollbackTargetCheckpointId !== None

let writeBatch = async (
  inMemoryStore: t,
  ~persistence: Persistence.t,
  ~batch,
  ~config,
  ~isInReorgThreshold,
) =>
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    JsError.throwWithMessage(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) =>
    let updatedEntities = persistence.allEntities->Belt.Array.keepMap(entityConfig => {
      let updates =
        inMemoryStore
        ->getInMemTable(~entityConfig)
        ->InMemoryTable.Entity.updates
      if updates->Utils.Array.isEmpty {
        None
      } else {
        Some(({entityConfig, updates}: Persistence.updatedEntity))
      }
    })
    await persistence.storage.writeBatch(
      ~batch,
      ~rawEvents=inMemoryStore.rawEvents->InMemoryTable.values,
      ~rollbackTargetCheckpointId=inMemoryStore.rollbackTargetCheckpointId,
      ~isInReorgThreshold,
      ~config,
      ~allEntities=persistence.allEntities,
      ~updatedEntities,
      ~updatedEffectsCache={
        let acc = []
        inMemoryStore.effects->Utils.Dict.forEach(inMemTable => {
          let {idsToStore, dict, effect, invalidationsCount} = inMemTable
          switch idsToStore {
          | [] => ()
          | ids =>
            let items = Belt.Array.makeUninitializedUnsafe(ids->Belt.Array.length)
            ids->Belt.Array.forEachWithIndex((index, id) => {
              items->Array.setUnsafe(
                index,
                (
                  {
                    id,
                    output: dict->Dict.getUnsafe(id),
                  }: Internal.effectCacheItem
                ),
              )
            })
            let effectName = effect.name
            let effectCacheRecord = switch cache->Utils.Dict.dangerouslyGetNonOption(effectName) {
            | Some(c) => c
            | None =>
              let c: Persistence.effectCacheRecord = {effectName, count: 0}
              cache->Dict.set(effectName, c)
              c
            }
            let shouldInitialize = effectCacheRecord.count === 0
            effectCacheRecord.count =
              effectCacheRecord.count + items->Array.length - invalidationsCount
            Prometheus.EffectCacheCount.set(~count=effectCacheRecord.count, ~effectName)
            acc
            ->Array.push(({effect, items, shouldInitialize}: Persistence.updatedEffectCache))
            ->ignore
          }
        })
        acc
      },
    )
    inMemoryStore->clear
  }

let prepareRollbackDiff = async (
  inMemoryStore: t,
  ~persistence: Persistence.t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
) => {
  inMemoryStore->clear
  inMemoryStore.rollbackTargetCheckpointId = Some(rollbackTargetCheckpointId)

  let deletedEntities = Dict.make()
  let setEntities = Dict.make()

  let _ = await persistence.allEntities
  ->Belt.Array.map(async entityConfig => {
    let entityTable = inMemoryStore->getInMemTable(~entityConfig)

    let (removedIdsResult, restoredEntitiesResult) = await persistence.storage.getRollbackData(
      ~entityConfig,
      ~rollbackTargetCheckpointId,
    )

    removedIdsResult->Array.forEach(data => {
      deletedEntities->Utils.Dict.push(entityConfig.name, data["id"])
      entityTable->InMemoryTable.Entity.set(
        Delete({
          entityId: data["id"],
          checkpointId: rollbackDiffCheckpointId,
        }),
        ~shouldSaveHistory=false,
        ~containsRollbackDiffChange=true,
      )
    })

    let restoredEntities = restoredEntitiesResult->S.parseOrThrow(entityConfig.rowsSchema)

    restoredEntities->Belt.Array.forEach((entity: Internal.entity) => {
      setEntities->Utils.Dict.push(entityConfig.name, entity.id)
      entityTable->InMemoryTable.Entity.set(
        Set({
          entityId: entity.id,
          checkpointId: rollbackDiffCheckpointId,
          entity,
        }),
        ~shouldSaveHistory=false,
        ~containsRollbackDiffChange=true,
      )
    })
  })
  ->Promise.all

  {
    "deletedEntities": deletedEntities,
    "setEntities": setEntities,
  }
}

let setBatchDcs = (inMemoryStore: t, ~batch: Batch.t, ~shouldSaveHistory) => {
  let inMemTable =
    inMemoryStore->getInMemTable(~entityConfig=InternalTable.EnvioAddresses.entityConfig)

  let itemIdx = ref(0)

  for checkpoint in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpoint)
    let chainId = batch.checkpointChainIds->Array.getUnsafe(checkpoint)
    let checkpointEventsProcessed = batch.checkpointEventsProcessed->Array.getUnsafe(checkpoint)

    for idx in 0 to checkpointEventsProcessed - 1 {
      let item = batch.items->Array.getUnsafe(itemIdx.contents + idx)
      switch item->Internal.getItemDcs {
      | None => ()
      | Some(dcs) =>
        // Currently only events support contract registration, so we can cast to event item
        let eventItem = item->Internal.castUnsafeEventItem
        for dcIdx in 0 to dcs->Array.length - 1 {
          let dc = dcs->Array.getUnsafe(dcIdx)
          let entity: InternalTable.EnvioAddresses.t = {
            id: InternalTable.EnvioAddresses.makeId(~chainId, ~address=dc.address),
            chainId,
            contractName: dc.contractName,
            registrationBlock: eventItem.blockNumber,
            registrationLogIndex: eventItem.logIndex,
          }

          inMemTable->InMemoryTable.Entity.set(
            Set({
              entityId: entity.id,
              checkpointId,
              entity: entity->InternalTable.EnvioAddresses.castToInternal,
            }),
            ~shouldSaveHistory,
          )
        }
      }
    }

    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}
