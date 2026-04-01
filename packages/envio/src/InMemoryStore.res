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
    ->Js.Dict.entries
    ->Belt.Array.map(((k, v)) => (k, v->InMemoryTable.Entity.clone))
    ->Js.Dict.fromArray
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
  // Addresses accumulated during this batch, to be written to DB
  addressesToWrite: array<Config.EnvioAddresses.t>,
}

let make = (~entities: array<Internal.entityConfig>, ~rollbackTargetCheckpointId=?): t => {
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  effects: Js.Dict.empty(),
  rollbackTargetCheckpointId,
  addressesToWrite: [],
}

let clone = (self: t) => {
  rawEvents: self.rawEvents->InMemoryTable.clone,
  entities: self.entities->EntityTables.clone,
  effects: Js.Dict.map(table => {
    idsToStore: table.idsToStore->Array.copy,
    invalidationsCount: table.invalidationsCount,
    dict: table.dict->Utils.Dict.shallowCopy,
    effect: table.effect,
  }, self.effects),
  rollbackTargetCheckpointId: self.rollbackTargetCheckpointId,
  addressesToWrite: self.addressesToWrite->Array.copy,
}

let getEffectInMemTable = (inMemoryStore: t, ~effect: Internal.effect) => {
  let key = effect.name
  switch inMemoryStore.effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table = {
      idsToStore: [],
      dict: Js.Dict.empty(),
      invalidationsCount: 0,
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

let isRollingBack = (inMemoryStore: t) => inMemoryStore.rollbackTargetCheckpointId !== None

let setBatchDcs = (inMemoryStore: t, ~batch: Batch.t, ~shouldSaveHistory as _) => {
  let itemIdx = ref(0)

  for checkpoint in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Js.Array2.unsafe_get(checkpoint)
    let chainId = batch.checkpointChainIds->Js.Array2.unsafe_get(checkpoint)
    let checkpointEventsProcessed =
      batch.checkpointEventsProcessed->Js.Array2.unsafe_get(checkpoint)

    for idx in 0 to checkpointEventsProcessed - 1 {
      let item = batch.items->Js.Array2.unsafe_get(itemIdx.contents + idx)
      switch item->Internal.getItemDcs {
      | None => ()
      | Some(dcs) =>
        // Currently only events support contract registration, so we can cast to event item
        let eventItem = item->Internal.castUnsafeEventItem
        for dcIdx in 0 to dcs->Array.length - 1 {
          let dc = dcs->Js.Array2.unsafe_get(dcIdx)
          let entry: Config.EnvioAddresses.t = {
            id: dc.address->Address.toString,
            chainId,
            contractName: dc.contractName,
            registeringEventBlock: eventItem.blockNumber,
            registeringEventLogIndex: Some(eventItem.logIndex),
            checkpointId,
          }
          inMemoryStore.addressesToWrite->Js.Array2.push(entry)->ignore
        }
      }
    }

    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}
