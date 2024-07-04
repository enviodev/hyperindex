open Belt

type t<'key, 'val> = {
  dict: dict<'val>,
  hash: 'key => string,
}

let make = (~hash): t<'key, 'val> => {dict: Js.Dict.empty(), hash}

let set = (self: t<'key, 'val>, key, value) => self.dict->Js.Dict.set(key->self.hash, value)

let get = (self: t<'key, 'val>, key: 'key) =>
  self.dict->Js.Dict.get(key->self.hash)

let values = (self: t<'key, 'val>) => self.dict->Js.Dict.values

@val external structuredClone: 'a => 'a = "structuredClone"
let clone = (self: t<'key, 'val>) => {
  ...self,
  dict: self.dict->structuredClone,
}

module Entity = {
  type t<'entity> = t<Types.id, Types.inMemoryStoreRowEntity<'entity>>
  let make = (): t<'entity> => {dict: Js.Dict.empty(), hash: str => str}

  let initValue = (
    // NOTE: This value is only set to true in the internals of the test framework to create the mockDb.
    ~allowOverWriteEntity=false,
    ~key: Types.id,
    ~entity: option<'entity>,
    inMemTable: t<'entity>,
  ) => {
    let shouldWriteEntity =
      allowOverWriteEntity || inMemTable.dict->Js.Dict.get(key->inMemTable.hash)->Option.isNone

    //Only initialize a row in the case where it is none
    //or if allowOverWriteEntity is true (used for mockDb in test helpers)
    if shouldWriteEntity {
      let initialStoreRow: Types.inMemoryStoreRowEntity<'entity> = switch entity {
      | Some(entity) => InitialReadFromDb(AlreadySet(entity))
      | None => InitialReadFromDb(NotSet)
      }
      inMemTable.dict->Js.Dict.set(key->inMemTable.hash, initialStoreRow)
    }
  }

  let set = (inMemTable: t<'entity>, entityUpdate: Types.entityUpdate<'entity>) => {
    let entityData: Types.inMemoryStoreRowEntity<'entity> = switch inMemTable->get(
      entityUpdate.entityId,
    ) {
    | Some(InitialReadFromDb(entity_read)) =>
      Updated({
        initial: Retrieved(entity_read),
        latest: entityUpdate,
        history: [],
      })
    | Some(Updated(previous_values))
      if !(Config.getConfig()->Config.shouldRollbackOnReorg) ||
      //Rollback initial state cases should not save history
      !previous_values.latest.shouldSaveHistory ||
      // This prevents two db actions in the same event on the same entity from being recorded to the history table.
      previous_values.latest.eventIdentifier == entityUpdate.eventIdentifier =>
      Updated({
        ...previous_values,
        latest: entityUpdate,
      })
    | Some(Updated(previous_values)) =>
      Updated({
        initial: previous_values.initial,
        latest: entityUpdate,
        history: previous_values.history->Array.concat([previous_values.latest]),
      })
    | None =>
      Updated({
        initial: Unknown,
        latest: entityUpdate,
        history: [],
      })
    }
    inMemTable->set(entityUpdate.entityId, entityData)
  }

  let rowToEntity = row =>
    switch row {
    | Types.Updated({latest: {entityUpdateAction: Set(entity)}}) => Some(entity)
    | Updated({latest: {entityUpdateAction: Delete}}) => None
    | InitialReadFromDb(AlreadySet(entity)) => Some(entity)
    | InitialReadFromDb(NotSet) => None
    }

  let get = (inMemTable: t<'entity>, key: Types.id) =>
    inMemTable
    ->get(key)
    ->Option.flatMap(rowToEntity)

  let values = (inMemTable: t<'entity>) => {
    inMemTable
    ->values
    ->Array.keepMap(rowToEntity)
  }
}
