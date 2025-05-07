@genType
type rawEventsKey = {
  chainId: int,
  eventId: string,
}

let hashRawEventsKey = (key: rawEventsKey) =>
  EventUtils.getEventIdKeyString(~chainId=key.chainId, ~eventId=key.eventId)

module EntityTables = {
  type t = dict<InMemoryTable.Entity.t<Entities.internalEntity>>
  exception UndefinedEntity(Enums.EntityType.t)
  let make = (entities: array<module(Entities.InternalEntity)>): t => {
    let init = Js.Dict.empty()
    entities->Belt.Array.forEach(entity => {
      let module(Entity) = entity
      init->Js.Dict.set((Entity.name :> string), InMemoryTable.Entity.make())
    })
    init
  }

  let get = (type entity, self: t, entityMod: module(Entities.Entity with type t = entity)) => {
    let module(Entity) = entityMod
    switch self->Utils.Dict.dangerouslyGetNonOption((Entity.name :> string)) {
    | Some(table) =>
      table->(
        Utils.magic: InMemoryTable.Entity.t<Entities.internalEntity> => InMemoryTable.Entity.t<
          entity,
        >
      )

    | None =>
      UndefinedEntity(Entity.name)->ErrorHandling.mkLogAndRaise(
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

type t = {
  eventSyncState: InMemoryTable.t<int, TablesStatic.EventSyncState.t>,
  rawEvents: InMemoryTable.t<rawEventsKey, TablesStatic.RawEvents.t>,
  entities: Js.Dict.t<InMemoryTable.Entity.t<Entities.internalEntity>>,
  rollBackEventIdentifier: option<Types.eventIdentifier>,
}

let make = (
  ~entities: array<module(Entities.InternalEntity)>=Entities.allEntities,
  ~rollBackEventIdentifier=?,
): t => {
  eventSyncState: InMemoryTable.make(~hash=v => v->Belt.Int.toString),
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  rollBackEventIdentifier,
}

let clone = (self: t) => {
  eventSyncState: self.eventSyncState->InMemoryTable.clone,
  rawEvents: self.rawEvents->InMemoryTable.clone,
  entities: self.entities->EntityTables.clone,
  rollBackEventIdentifier: self.rollBackEventIdentifier->Lodash.cloneDeep,
}

let getInMemTable = (
  type entity,
  inMemoryStore: t,
  ~entityMod: module(Entities.Entity with type t = entity),
): InMemoryTable.Entity.t<entity> => {
  inMemoryStore.entities->EntityTables.get(entityMod)
}

let isRollingBack = (inMemoryStore: t) => inMemoryStore.rollBackEventIdentifier->Belt.Option.isSome

let setDcsToStore = (
  inMemoryStore: t,
  dcsToStoreByChainId: dict<array<FetchState.indexingContract>>,
  ~shouldSaveHistory,
) => {
  let inMemTable =
    inMemoryStore.entities->EntityTables.get(module(TablesStatic.DynamicContractRegistry))
  dcsToStoreByChainId->Utils.Dict.forEachWithKey((chainId, dcs) => {
    let chainId = chainId->Belt.Int.fromString->Belt.Option.getExn
    dcs->Belt.Array.forEach(dc => {
      let dcData = switch dc.register {
      | Config => Js.Exn.raiseError("Config contract should not be in dcsToStore")
      | DC(data) => data
      }
      let entity: TablesStatic.DynamicContractRegistry.t = {
        id: TablesStatic.DynamicContractRegistry.makeId(~chainId, ~contractAddress=dc.address),
        chainId,
        contractAddress: dc.address,
        contractType: dc.contractName->(Utils.magic: string => Enums.ContractType.t),
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
        Set(entity)->Types.mkEntityUpdate(~eventIdentifier, ~entityId=entity.id),
        ~shouldSaveHistory,
      )
    })
  })
}
