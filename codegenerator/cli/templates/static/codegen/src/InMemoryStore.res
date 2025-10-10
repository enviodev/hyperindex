@genType
type rawEventsKey = {
  chainId: int,
  eventId: string,
}

let hashRawEventsKey = (key: rawEventsKey) =>
  EventUtils.getEventIdKeyString(~chainId=key.chainId, ~eventId=key.eventId)

module EntityTables = {
  type t = dict<InMemoryTable.Entity.t<Entities.internalEntity>>
  exception UndefinedEntity({entityName: string})
  let make = (entities: array<Internal.entityConfig>): t => {
    let init = Js.Dict.empty()
    entities->Belt.Array.forEach(entityConfig => {
      init->Js.Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
    })
    init
  }

  let get = (type entity, self: t, ~entityName: string) => {
    switch self->Utils.Dict.dangerouslyGetNonOption(entityName) {
    | Some(table) =>
      table->(
        Utils.magic: InMemoryTable.Entity.t<Entities.internalEntity> => InMemoryTable.Entity.t<
          entity,
        >
      )

    | None =>
      UndefinedEntity({entityName: entityName})->ErrorHandling.mkLogAndRaise(
        ~msg="Unexpected, entity InMemoryTable is undefined",
      )
    }
  }

  let clone = (self: t) => {
    self
    ->Js.Dict.entries
    ->Belt.Array.map(((k, v)) => (k, v->InMemoryTable.Entity.clone))
    ->Js.Dict.fromArray
  }
}

type effectCacheInMemTable = {
  idsToStore: array<string>,
  dict: dict<Internal.effectOutput>,
  effect: Internal.effect,
}

type t = {
  rawEvents: InMemoryTable.t<rawEventsKey, InternalTable.RawEvents.t>,
  entities: dict<InMemoryTable.Entity.t<Entities.internalEntity>>,
  effects: dict<effectCacheInMemTable>,
  rollBackEventIdentifier: option<Types.eventIdentifier>,
  rollbackTargetCheckpointId: option<int>,
}

let make = (
  ~entities: array<Internal.entityConfig>=Entities.allEntities,
  ~rollBackEventIdentifier=?,
  ~rollbackTargetCheckpointId=?,
): t => {
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  effects: Js.Dict.empty(),
  rollBackEventIdentifier,
  rollbackTargetCheckpointId,
}

let clone = (self: t) => {
  rawEvents: self.rawEvents->InMemoryTable.clone,
  entities: self.entities->EntityTables.clone,
  effects: Js.Dict.map(table => {
    idsToStore: table.idsToStore->Array.copy,
    dict: table.dict->Utils.Dict.shallowCopy,
    effect: table.effect,
  }, self.effects),
  rollBackEventIdentifier: self.rollBackEventIdentifier->Lodash.cloneDeep,
  rollbackTargetCheckpointId: self.rollbackTargetCheckpointId,
}

let getEffectInMemTable = (inMemoryStore: t, ~effect: Internal.effect) => {
  let key = effect.name
  switch inMemoryStore.effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table = {
      idsToStore: [],
      dict: Js.Dict.empty(),
      effect,
    }
    inMemoryStore.effects->Js.Dict.set(key, table)
    table
  }
}

let getInMemTable = (
  inMemoryStore: t,
  ~entityConfig: Internal.entityConfig,
): InMemoryTable.Entity.t<Internal.entity> => {
  inMemoryStore.entities->EntityTables.get(~entityName=entityConfig.name)
}

let isRollingBack = (inMemoryStore: t) => inMemoryStore.rollBackEventIdentifier->Belt.Option.isSome

let setBatchDcs = (inMemoryStore: t, ~batch: Batch.t, ~shouldSaveHistory) => {
  let inMemTable =
    inMemoryStore->getInMemTable(
      ~entityConfig=module(InternalTable.DynamicContractRegistry)->Entities.entityModToInternal,
    )

  let itemIdx = ref(0)

  for checkpoint in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Js.Array2.unsafe_get(checkpoint)
    let chainId = batch.checkpointChainIds->Js.Array2.unsafe_get(checkpoint)
    let checkpointEventsProcessed =
      batch.checkpointEventsProcessed->Js.Array2.unsafe_get(checkpoint)

    for itemIdx in 0 to batch.items->Array.length - 1 {
      let item = batch.items->Js.Array2.unsafe_get(itemIdx)
      switch item->Internal.getItemDcs {
      | None => ()
      | Some(dcs) =>
        // Currently only events support contract registration, so we can cast to event item
        let eventItem = item->Internal.castUnsafeEventItem
        for dcIdx in 0 to dcs->Array.length - 1 {
          let dc = dcs->Js.Array2.unsafe_get(dcIdx)
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

          let eventIdentifier: Types.eventIdentifier = {
            chainId,
            blockTimestamp: 0,
            blockNumber: dc.startBlock,
            logIndex: eventItem.logIndex,
          }
          inMemTable->InMemoryTable.Entity.set(
            Set(entity->InternalTable.DynamicContractRegistry.castToInternal)->Types.mkEntityUpdate(
              ~eventIdentifier,
              ~entityId=entity.id,
              ~checkpointId,
            ),
            ~shouldSaveHistory,
          )
        }
      }
    }

    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}
