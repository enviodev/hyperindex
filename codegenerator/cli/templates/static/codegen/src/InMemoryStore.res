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
}

let make = (
  ~entities: array<Internal.entityConfig>=Entities.allEntities,
  ~rollBackEventIdentifier=?,
): t => {
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  effects: Js.Dict.empty(),
  rollBackEventIdentifier,
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

let setDcsToStore = (
  inMemoryStore: t,
  dcsToStoreByChainId: dict<array<FetchState.indexingContract>>,
  ~shouldSaveHistory,
) => {
  let inMemTable =
    inMemoryStore->getInMemTable(
      ~entityConfig=module(InternalTable.DynamicContractRegistry)->Entities.entityModToInternal,
    )
  dcsToStoreByChainId->Utils.Dict.forEachWithKey((chainId, dcs) => {
    let chainId = chainId->Belt.Int.fromString->Belt.Option.getExn
    dcs->Belt.Array.forEach(dc => {
      let dcData = switch dc.register {
      | Config => Js.Exn.raiseError("Config contract should not be in dcsToStore")
      | DC(data) => data
      }
      let entity: InternalTable.DynamicContractRegistry.t = {
        id: InternalTable.DynamicContractRegistry.makeId(~chainId, ~contractAddress=dc.address),
        chainId,
        contractAddress: dc.address,
        contractName: dc.contractName,
        registeringEventBlockNumber: dc.startBlock,
        registeringEventBlockTimestamp: dcData.registeringEventBlockTimestamp,
        registeringEventLogIndex: dcData.registeringEventLogIndex,
        registeringEventContractName: dcData.registeringEventContractName,
        registeringEventName: dcData.registeringEventName,
        registeringEventSrcAddress: dcData.registeringEventSrcAddress,
      }

      let eventIdentifier: Types.eventIdentifier = {
        chainId,
        blockTimestamp: dcData.registeringEventBlockTimestamp,
        blockNumber: dc.startBlock,
        logIndex: dcData.registeringEventLogIndex,
      }
      inMemTable->InMemoryTable.Entity.set(
        Set(entity->InternalTable.DynamicContractRegistry.castToInternal)->Types.mkEntityUpdate(
          ~eventIdentifier,
          ~entityId=entity.id,
        ),
        ~shouldSaveHistory,
      )
    })
  })
}
