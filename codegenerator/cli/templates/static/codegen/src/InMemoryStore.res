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

  let get = (type entity, self: t, ~entityConfig: Internal.entityConfig) => {
    switch self->Utils.Dict.dangerouslyGetNonOption(entityConfig.name) {
    | Some(table) =>
      table->(
        Utils.magic: InMemoryTable.Entity.t<Entities.internalEntity> => InMemoryTable.Entity.t<
          entity,
        >
      )

    | None =>
      UndefinedEntity({entityName: entityConfig.name})->ErrorHandling.mkLogAndRaise(
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
  entities: dict<InMemoryTable.Entity.t<Entities.internalEntity>>,
  effects: dict<InMemoryTable.t<Internal.effectInput, Internal.effectOutput>>,
  rollBackEventIdentifier: option<Types.eventIdentifier>,
}

let make = (
  ~entities: array<Internal.entityConfig>=Entities.allEntities,
  ~rollBackEventIdentifier=?,
): t => {
  eventSyncState: InMemoryTable.make(~hash=v => v->Belt.Int.toString),
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  effects: Js.Dict.empty(),
  rollBackEventIdentifier,
}

let clone = (self: t) => {
  eventSyncState: self.eventSyncState->InMemoryTable.clone,
  rawEvents: self.rawEvents->InMemoryTable.clone,
  entities: self.entities->EntityTables.clone,
  effects: Js.Dict.map(table => table->InMemoryTable.clone, self.effects),
  rollBackEventIdentifier: self.rollBackEventIdentifier->Lodash.cloneDeep,
}

let getEffectInMemTable = (inMemoryStore: t, ~effect: Internal.effect) => {
  let key = effect.name
  switch inMemoryStore.effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table = InMemoryTable.make(~hash=Utils.Hash.makeOrThrow)
    inMemoryStore.effects->Js.Dict.set(key, table)
    table
  }
}

let getInMemTable = (
  inMemoryStore: t,
  ~entityConfig: Internal.entityConfig,
): InMemoryTable.Entity.t<Internal.entity> => {
  inMemoryStore.entities->EntityTables.get(~entityConfig)
}

let isRollingBack = (inMemoryStore: t) => inMemoryStore.rollBackEventIdentifier->Belt.Option.isSome

let setDcsToStore = (
  inMemoryStore: t,
  dcsToStoreByChainId: dict<array<FetchState.indexingContract>>,
  ~shouldSaveHistory,
) => {
  let inMemTable =
    inMemoryStore.entities->EntityTables.get(
      ~entityConfig=module(TablesStatic.DynamicContractRegistry)->Entities.entityModToInternal,
    )
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
