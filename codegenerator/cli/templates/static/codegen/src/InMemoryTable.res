module StdSet = Set

external arrayFromSet: StdSet.t<'a> => array<'a> = "Array.from"
open Belt

type t<'key, 'val> = {
  dict: Js.Dict.t<'val>,
  hash: 'key => string,
}

let make = (~hash): t<'key, 'val> => {dict: Js.Dict.empty(), hash}

let set = (self: t<'key, 'val>, key, value) => self.dict->Js.Dict.set(key->self.hash, value)

let get = (self: t<'key, 'val>, key: 'key) => self.dict->Js.Dict.get(key->self.hash)

let values = (self: t<'key, 'val>) => self.dict->Js.Dict.values

@val external structuredClone: 'a => 'a = "structuredClone"
let clone = (self: t<'key, 'val>) => {
  ...self,
  dict: self.dict->structuredClone,
}

module Entity = {
  type relatedEntityId = Types.id
  type indexWithRelatedIds = (TableIndices.Index.t, StdSet.t<relatedEntityId>)
  type indicesSerializedToValue = t<TableIndices.Index.t, indexWithRelatedIds>
  type indexFieldNameToIndices = t<TableIndices.Index.t, indicesSerializedToValue>
  type t<'entity> = {
    table: t<Types.id, Types.inMemoryStoreRowEntity<'entity>>,
    fieldNameIndices: indexFieldNameToIndices,
  }

  let makeIndicesSerializedToValue = (
    ~index,
    ~relatedEntityIds=StdSet.make(),
  ): indicesSerializedToValue => {
    let empty = make(~hash=TableIndices.Index.toString)
    empty->set(index, (index, relatedEntityIds))
    empty
  }

  let make = (): t<'entity> => {
    table: make(~hash=str => str),
    fieldNameIndices: make(~hash=TableIndices.Index.getFieldName),
  }

  exception UndefinedKey(string)
  let updateIndices = (self: t<'entity>, ~entity: 'entity) =>
    self.fieldNameIndices.dict
    ->Js.Dict.keys
    ->Array.forEach(fieldName => {
      switch (
        entity
        ->(Utils.magic: 'entity => Js.Dict.t<TableIndices.FieldValue.t>)
        ->Js.Dict.get(fieldName),
        self.fieldNameIndices.dict->Js.Dict.get(fieldName),
      ) {
      | (Some(fieldValue), Some(indices)) =>
        indices
        ->values
        ->Array.forEach(((index, relatedEntityIds)) => {
          if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
            relatedEntityIds->StdSet.add(Entities.getEntityIdUnsafe(entity))->ignore
          }
        })
      | _ =>
        UndefinedKey(fieldName)->ErrorHandling.mkLogAndRaise(
          ~msg="Expected field name to exist on the referenced index and the provided entity",
        )
      }
    })

  let deleteEntityFromIndices = (self: t<'entity>, ~entityId: Entities.id) =>
    self.fieldNameIndices
    ->values
    ->Array.forEach(indicesSerializedToValue => {
      indicesSerializedToValue
      ->values
      ->Array.forEach(((_index, relatedEntityIds)) => {
        let _wasRemoved = relatedEntityIds->StdSet.delete(entityId)
      })
    })

  let initValue = (
    // NOTE: This value is only set to true in the internals of the test framework to create the mockDb.
    ~allowOverWriteEntity=false,
    ~key: Types.id,
    ~entity: option<'entity>,
    inMemTable: t<'entity>,
  ) => {
    let shouldWriteEntity =
      allowOverWriteEntity ||
      inMemTable.table.dict->Js.Dict.get(key->inMemTable.table.hash)->Option.isNone

    //Only initialize a row in the case where it is none
    //or if allowOverWriteEntity is true (used for mockDb in test helpers)
    if shouldWriteEntity {
      let initialStoreRow: Types.inMemoryStoreRowEntity<'entity> = switch entity {
      | Some(entity) =>
        //update table indices in the case where there
        //is an already set entity
        inMemTable->updateIndices(~entity)
        InitialReadFromDb(AlreadySet(entity))

      | None => InitialReadFromDb(NotSet)
      }
      inMemTable.table.dict->Js.Dict.set(key->inMemTable.table.hash, initialStoreRow)
    }
  }

  let setRow = set
  let set = (inMemTable: t<'entity>, entityUpdate: Types.entityUpdate<'entity>) => {
    let entityData: Types.inMemoryStoreRowEntity<'entity> = switch inMemTable.table->get(
      entityUpdate.entityId,
    ) {
    | Some(InitialReadFromDb(entity_read)) =>
      Updated({
        initial: Retrieved(entity_read),
        latest: entityUpdate,
        history: [],
      })
    | Some(Updated(previous_values))
      if !(Config.getGenerated()->Config.shouldRollbackOnReorg) ||
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
    inMemTable.table->setRow(entityUpdate.entityId, entityData)
    switch entityUpdate.entityUpdateAction {
    | Set(entity) => inMemTable->updateIndices(~entity)
    | Delete => inMemTable->deleteEntityFromIndices(~entityId=entityUpdate.entityId)
    }
  }

  let rowToEntity = row =>
    switch row {
    | Types.Updated({latest: {entityUpdateAction: Set(entity)}}) => Some(entity)
    | Updated({latest: {entityUpdateAction: Delete}}) => None
    | InitialReadFromDb(AlreadySet(entity)) => Some(entity)
    | InitialReadFromDb(NotSet) => None
    }

  let getRow = get

  let get = (inMemTable: t<'entity>, key: Types.id) =>
    inMemTable.table
    ->get(key)
    ->Option.flatMap(rowToEntity)

  let getOnIndex = (inMemTable: t<'entity>, ~index: TableIndices.Index.t) => {
    inMemTable.fieldNameIndices
    ->getRow(index)
    ->Option.flatMap(indicesSerializedToValue => {
      indicesSerializedToValue
      ->getRow(index)
      ->Option.map(((_index, relatedEntityIds)) => {
        let res = relatedEntityIds->arrayFromSet->Array.keepMap(get(inMemTable, ...))
        res
      })
    })
    ->Option.getWithDefault([])
  }

  let indexDoesNotExists = (inMemTable: t<'entity>, ~index) => {
    inMemTable.fieldNameIndices->getRow(index)->Option.flatMap(getRow(_, index))->Option.isNone
  }

  let addEmptyIndex = (inMemTable: t<'entity>, ~index) => {
    switch inMemTable.fieldNameIndices->getRow(index) {
    | None => inMemTable.fieldNameIndices->setRow(index, makeIndicesSerializedToValue(~index))
    | Some(indicesSerializedToValue) =>
      switch indicesSerializedToValue->getRow(index) {
      | None => indicesSerializedToValue->setRow(index, (index, StdSet.make()))
      | Some(_) => ()
      }
    }
  }

  let addIdToIndex = (inMemTable: t<'entity>, ~index, ~entityId) =>
    switch inMemTable.fieldNameIndices->getRow(index) {
    | None =>
      inMemTable.fieldNameIndices->setRow(
        index,
        makeIndicesSerializedToValue(~index, ~relatedEntityIds=StdSet.make()->StdSet.add(entityId)),
      )
    | Some(indicesSerializedToValue) =>
      switch indicesSerializedToValue->getRow(index) {
      | None =>
        indicesSerializedToValue->setRow(index, (index, StdSet.make()->StdSet.add(entityId)))
      | Some((_index, relatedEntityIds)) => relatedEntityIds->StdSet.add(entityId)->ignore
      }
    }

  let values = (inMemTable: t<'entity>) => {
    inMemTable.table
    ->values
    ->Array.keepMap(rowToEntity)
  }

  let clone = ({table, fieldNameIndices}: t<'entity>) => {
    table: table->clone,
    fieldNameIndices: {
      ...fieldNameIndices,
      dict: fieldNameIndices.dict
      ->Js.Dict.entries
      ->Array.map(((k, v)) => (k, v->clone))
      ->Js.Dict.fromArray,
    },
  }
}
