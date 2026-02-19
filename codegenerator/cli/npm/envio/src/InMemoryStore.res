@genType
type rawEventsKey = {
  chainId: int,
  eventId: string,
}

let hashRawEventsKey = (key: rawEventsKey) =>
  EventUtils.getEventIdKeyString(~chainId=key.chainId, ~eventId=key.eventId)

module EntityTables = {
  type t = dict<InMemoryTable.Entity.t<Internal.entity>>
  exception UndefinedEntity({entityName: string})
  let make = (entities: array<Internal.entityConfig>): t => {
    let init = Dict.make()
    entities->Belt.Array.forEach(entityConfig => {
      init->Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
    })
    init
  }

  let get = (type entity, self: t, ~entityName: string) => {
    switch self->Utils.Dict.dangerouslyGetNonOption(entityName) {
    | Some(table) =>
      table->(
        Utils.magic: InMemoryTable.Entity.t<Internal.entity> => InMemoryTable.Entity.t<entity>
      )

    | None =>
      UndefinedEntity({entityName: entityName})->ErrorHandling.mkLogAndRaise(
        ~msg="Unexpected, entity InMemoryTable is undefined",
      )
    }
  }

  let clone = (self: t) => {
    self
    ->Dict.toArray
    ->Belt.Array.map(((k, v)) => (k, v->InMemoryTable.Entity.clone))
    ->Dict.fromArray
  }
}

type effectCacheInMemTable = {
  idsToStore: array<string>,
  mutable invalidationsCount: int,
  dict: dict<Internal.effectOutput>,
  effect: Internal.effect,
}

type t = {
  rawEvents: InMemoryTable.t<rawEventsKey, InternalTable.RawEvents.t>,
  entities: dict<InMemoryTable.Entity.t<Internal.entity>>,
  effects: dict<effectCacheInMemTable>,
  rollbackTargetCheckpointId: option<Internal.checkpointId>,
}

let make = (~entities: array<Internal.entityConfig>, ~rollbackTargetCheckpointId=?): t => {
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  effects: Dict.make(),
  rollbackTargetCheckpointId,
}

let clone = (self: t) => {
  rawEvents: self.rawEvents->InMemoryTable.clone,
  entities: self.entities->EntityTables.clone,
  effects: Dict.mapValues(self.effects, table => {
    idsToStore: table.idsToStore->Array.copy,
    invalidationsCount: table.invalidationsCount,
    dict: table.dict->Utils.Dict.shallowCopy,
    effect: table.effect,
  }),
  rollbackTargetCheckpointId: self.rollbackTargetCheckpointId,
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
): InMemoryTable.Entity.t<Internal.entity> => {
  inMemoryStore.entities->EntityTables.get(~entityName=entityConfig.name)
}

let isRollingBack = (inMemoryStore: t) => inMemoryStore.rollbackTargetCheckpointId !== None

let setBatchDcs = (inMemoryStore: t, ~batch: Batch.t, ~shouldSaveHistory) => {
  let inMemTable =
    inMemoryStore->getInMemTable(~entityConfig=InternalTable.DynamicContractRegistry.entityConfig)

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
          let entity: InternalTable.DynamicContractRegistry.t = {
            id: InternalTable.DynamicContractRegistry.makeId(~chainId, ~contractAddress=dc.address),
            chainId,
            contractAddress: dc.address,
            contractName: dc.contractName,
            registeringEventBlockNumber: eventItem.blockNumber,
            registeringEventLogIndex: eventItem.logIndex,
            registeringEventBlockTimestamp: eventItem.timestamp,
            registeringEventContractName: eventItem.eventConfig.contractName,
            registeringEventName: eventItem.eventConfig.name,
            registeringEventSrcAddress: eventItem.event.srcAddress,
          }

          inMemTable->InMemoryTable.Entity.set(
            Set({
              entityId: entity.id,
              checkpointId,
              entity: entity->InternalTable.DynamicContractRegistry.castToInternal,
            }),
            ~shouldSaveHistory,
          )
        }
      }
    }

    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}
