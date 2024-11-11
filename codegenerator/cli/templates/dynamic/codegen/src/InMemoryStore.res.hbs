@genType
type rawEventsKey = {
  chainId: int,
  eventId: string,
}

let hashRawEventsKey = (key: rawEventsKey) =>
  EventUtils.getEventIdKeyString(~chainId=key.chainId, ~eventId=key.eventId)

@genType
type dynamicContractRegistryKey = {
  chainId: int,
  contractAddress: Address.t,
}

let hashDynamicContractRegistryKey = ({chainId, contractAddress}) =>
  EventUtils.getContractAddressKeyString(~chainId, ~contractAddress)

module EntityTables = {
  type t = dict<InMemoryTable.Entity.t<Entities.internalEntity>>
  exception UndefinedEntity(string)
  let make = (entities: array<module(Entities.InternalEntity)>): t => {
    let init = Js.Dict.empty()
    entities->Belt.Array.forEach(entity => {
      let module(Entity) = entity
      init->Js.Dict.set(Entity.key, InMemoryTable.Entity.make())
    })
    init
  }

  let get = (type entity, self: t, entityMod: module(Entities.Entity with type t = entity)) => {
    let module(Entity) = entityMod
    switch self->Utils.Dict.dangerouslyGetNonOption(Entity.key) {
    | Some(table) =>
      table->(
        Utils.magic: InMemoryTable.Entity.t<Entities.internalEntity> => InMemoryTable.Entity.t<
          entity,
        >
      )

    | None =>
      UndefinedEntity(Entity.key)->ErrorHandling.mkLogAndRaise(
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
  dynamicContractRegistry: InMemoryTable.t<
    dynamicContractRegistryKey,
    TablesStatic.DynamicContractRegistry.t,
  >,
  entities: Js.Dict.t<InMemoryTable.Entity.t<Entities.internalEntity>>,
  rollBackEventIdentifier: option<Types.eventIdentifier>,
}

let make = (
  ~entities: array<module(Entities.InternalEntity)>=Entities.allEntities,
  ~rollBackEventIdentifier=None,
): t => {
  eventSyncState: InMemoryTable.make(~hash=v => v->Belt.Int.toString),
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  dynamicContractRegistry: InMemoryTable.make(~hash=hashDynamicContractRegistryKey),
  entities: EntityTables.make(entities),
  rollBackEventIdentifier,
}

let clone = (self: t) => {
  eventSyncState: self.eventSyncState->InMemoryTable.clone,
  rawEvents: self.rawEvents->InMemoryTable.clone,
  dynamicContractRegistry: self.dynamicContractRegistry->InMemoryTable.clone,
  entities: self.entities->EntityTables.clone,
  rollBackEventIdentifier: self.rollBackEventIdentifier->InMemoryTable.structuredClone,
}

let getInMemTable = (
  type entity,
  inMemoryStore: t,
  ~entityMod: module(Entities.Entity with type t = entity),
): InMemoryTable.Entity.t<entity> => {
  let module(Entity) = entityMod->Entities.entityModToInternal
  inMemoryStore->Utils.magic->Js.Dict.unsafeGet(Entity.key)
}
