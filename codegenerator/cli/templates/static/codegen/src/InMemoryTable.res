open Belt

type t<'key, 'val> = {
  dict: dict<'val>,
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
  type indexWithRelatedIds = (TableIndices.Index.t, Utils.Set.t<relatedEntityId>)
  type indicesSerializedToValue = t<TableIndices.Index.t, indexWithRelatedIds>
  type indexFieldNameToIndices = t<TableIndices.Index.t, indicesSerializedToValue>

  type entityWithIndices<'entity> = {
    entityRow: Types.inMemoryStoreRowEntity<'entity>,
    entityIndices: Utils.Set.t<TableIndices.Index.t>,
  }
  type t<'entity> = {
    table: t<Types.id, entityWithIndices<'entity>>,
    fieldNameIndices: indexFieldNameToIndices,
  }

  let makeIndicesSerializedToValue = (
    ~index,
    ~relatedEntityIds=Utils.Set.make(),
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
  let updateIndices = (
    self: t<'entity>,
    ~entity: 'entity,
    ~entityIndices: Utils.Set.t<TableIndices.Index.t>,
  ) => {
    //Remove any invalid indices on entity
    entityIndices->Utils.Set.forEach(index => {
      let fieldName = index->TableIndices.Index.getFieldName
      let fieldValue =
        entity
        ->(Utils.magic: 'entity => dict<TableIndices.FieldValue.t>)
        ->Js.Dict.get(fieldName)
        ->Option.getUnsafe
      if !(index->TableIndices.Index.evaluate(~fieldName, ~fieldValue)) {
        entityIndices->Utils.Set.delete(index)->ignore
      }
    })

    self.fieldNameIndices.dict
    ->Js.Dict.keys
    ->Array.forEach(fieldName => {
      switch (
        entity
        ->(Utils.magic: 'entity => dict<TableIndices.FieldValue.t>)
        ->Js.Dict.get(fieldName),
        self.fieldNameIndices.dict->Js.Dict.get(fieldName),
      ) {
      | (Some(fieldValue), Some(indices)) =>
        indices
        ->values
        ->Array.forEach(((index, relatedEntityIds)) => {
          if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
            //Add entity id to indices and add index to entity indicies
            relatedEntityIds->Utils.Set.add(Entities.getEntityIdUnsafe(entity))->ignore
            entityIndices->Utils.Set.add(index)->ignore
          }
        })
      | _ =>
        UndefinedKey(fieldName)->ErrorHandling.mkLogAndRaise(
          ~msg="Expected field name to exist on the referenced index and the provided entity",
        )
      }
    })
  }

  let deleteEntityFromIndices = (self: t<'entity>, ~entityId: Entities.id, ~entityIndices) =>
    entityIndices->Utils.Set.forEach(index => {
      switch self.fieldNameIndices
      ->get(index)
      ->Option.flatMap(get(_, index)) {
      | Some((_index, relatedEntityIds)) =>
        let _wasRemoved = relatedEntityIds->Utils.Set.delete(entityId)
      | None => () //Unexpected index should exist if it is entityIndices
      }
      let _wasRemoved = entityIndices->Utils.Set.delete(index)
    })

  let initValue = (
    inMemTable: t<'entity>,
    ~key: Types.id,
    ~entity: option<'entity>,
    // NOTE: This value is only set to true in the internals of the test framework to create the mockDb.
    ~allowOverWriteEntity=false,
  ) => {
    let shouldWriteEntity =
      allowOverWriteEntity ||
      inMemTable.table.dict->Js.Dict.get(key->inMemTable.table.hash)->Option.isNone

    //Only initialize a row in the case where it is none
    //or if allowOverWriteEntity is true (used for mockDb in test helpers)
    if shouldWriteEntity {
      let entityIndices = Utils.Set.make()
      let initialStoreRow: Types.inMemoryStoreRowEntity<'entity> = switch entity {
      | Some(entity) =>
        //update table indices in the case where there
        //is an already set entity
        inMemTable->updateIndices(~entity, ~entityIndices)
        InitialReadFromDb(AlreadySet(entity))

      | None => InitialReadFromDb(NotSet)
      }
      inMemTable.table.dict->Js.Dict.set(
        key->inMemTable.table.hash,
        {entityRow: initialStoreRow, entityIndices},
      )
    }
  }

  let setRow = set
  let set = (
    inMemTable: t<'entity>,
    entityUpdate: Types.entityUpdate<'entity>,
    ~shouldRollbackOnReorg,
  ) => {
    let {entityRow, entityIndices} = switch inMemTable.table->get(entityUpdate.entityId) {
    | Some({entityRow: InitialReadFromDb(entity_read), entityIndices}) =>
      let entityRow = Types.Updated({
        initial: Retrieved(entity_read),
        latest: entityUpdate,
        history: [],
      })
      {entityRow, entityIndices}
    | Some({entityRow: Updated(previous_values), entityIndices})
      if !shouldRollbackOnReorg ||
      //Rollback initial state cases should not save history
      !previous_values.latest.shouldSaveHistory ||
      // This prevents two db actions in the same event on the same entity from being recorded to the history table.
      previous_values.latest.eventIdentifier == entityUpdate.eventIdentifier =>
      let entityRow = Types.Updated({
        ...previous_values,
        latest: entityUpdate,
      })
      {entityRow, entityIndices}
    | Some({entityRow: Updated(previous_values), entityIndices}) =>
      let entityRow = Types.Updated({
        initial: previous_values.initial,
        latest: entityUpdate,
        history: previous_values.history->Array.concat([previous_values.latest]),
      })
      {entityRow, entityIndices}
    | None =>
      let entityRow = Types.Updated({
        initial: Unknown,
        latest: entityUpdate,
        history: [],
      })
      {entityRow, entityIndices: Utils.Set.make()}
    }
    switch entityUpdate.entityUpdateAction {
    | Set(entity) => inMemTable->updateIndices(~entity, ~entityIndices)
    | Delete => inMemTable->deleteEntityFromIndices(~entityId=entityUpdate.entityId, ~entityIndices)
    }
    inMemTable.table->setRow(entityUpdate.entityId, {entityRow, entityIndices})
  }

  let rowToEntity = row =>
    switch row.entityRow {
    | Types.Updated({latest: {entityUpdateAction: Set(entity)}}) => Some(entity)
    | Updated({latest: {entityUpdateAction: Delete}}) => None
    | InitialReadFromDb(AlreadySet(entity)) => Some(entity)
    | InitialReadFromDb(NotSet) => None
    }

  let getRow = get

  /** It returns option<option<'entity>> where the first option means
  that the entity is not set to the in memory store,
  and the second option means that the entity doesn't esist/deleted.
  It's needed to prevent an additional round trips to the database for deleted entities. */
  let get = (inMemTable: t<'entity>, key: Types.id) =>
    inMemTable.table
    ->get(key)
    ->Option.map(rowToEntity)

  let getOnIndex = (inMemTable: t<'entity>, ~index: TableIndices.Index.t) => {
    inMemTable.fieldNameIndices
    ->getRow(index)
    ->Option.flatMap(indicesSerializedToValue => {
      indicesSerializedToValue
      ->getRow(index)
      ->Option.map(((_index, relatedEntityIds)) => {
        let res =
          relatedEntityIds
          ->Utils.Set.toArray
          ->Array.keepMap(entityId => inMemTable->get(entityId)->Utils.Option.flatten)
        res
      })
    })
    ->Option.getWithDefault([])
  }

  let indexDoesNotExists = (inMemTable: t<'entity>, ~index) => {
    inMemTable.fieldNameIndices->getRow(index)->Option.flatMap(getRow(_, index))->Option.isNone
  }

  let addEmptyIndex = (inMemTable: t<'entity>, ~index) => {
    let fieldName = index->TableIndices.Index.getFieldName
    let relatedEntityIds = Utils.Set.make()

    inMemTable.table
    ->values
    ->Array.forEach(row => {
      switch row->rowToEntity {
      | Some(entity) =>
        let fieldValue =
          entity
          ->(Utils.magic: 'entity => dict<TableIndices.FieldValue.t>)
          ->Js.Dict.unsafeGet(fieldName)
        if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
          let _ = row.entityIndices->Utils.Set.add(index)
          let _ = relatedEntityIds->Utils.Set.add(entity->Entities.getEntityIdUnsafe)
        }
      | None => ()
      }
    })
    switch inMemTable.fieldNameIndices->getRow(index) {
    | None =>
      inMemTable.fieldNameIndices->setRow(
        index,
        makeIndicesSerializedToValue(~index, ~relatedEntityIds),
      )
    | Some(indicesSerializedToValue) =>
      switch indicesSerializedToValue->getRow(index) {
      | None => indicesSerializedToValue->setRow(index, (index, relatedEntityIds))
      | Some(_) => () //Should not happen, this means the index already exists
      }
    }
  }

  let addIdToIndex = (inMemTable: t<'entity>, ~index, ~entityId) =>
    switch inMemTable.fieldNameIndices->getRow(index) {
    | None =>
      inMemTable.fieldNameIndices->setRow(
        index,
        makeIndicesSerializedToValue(
          ~index,
          ~relatedEntityIds=Utils.Set.make()->Utils.Set.add(entityId),
        ),
      )
    | Some(indicesSerializedToValue) =>
      switch indicesSerializedToValue->getRow(index) {
      | None =>
        indicesSerializedToValue->setRow(index, (index, Utils.Set.make()->Utils.Set.add(entityId)))
      | Some((_index, relatedEntityIds)) => relatedEntityIds->Utils.Set.add(entityId)->ignore
      }
    }

  let rows = (inMemTable: t<'entity>) => {
    inMemTable.table
    ->values
    ->Array.map(v => v.entityRow)
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
