open Belt

type t<'key, 'val> = {
  dict: dict<'val>,
  hash: 'key => string,
}

let make = (~hash): t<'key, 'val> => {
  dict: Js.Dict.empty(),
  hash,
}

let set = (self: t<'key, 'val>, key, value) => self.dict->Js.Dict.set(key->self.hash, value)

let setByHash = (self: t<'key, 'val>, hash, value) => self.dict->Js.Dict.set(hash, value)

let hasByHash = (self: t<'key, 'val>, hash) => {
  self.dict->Utils.Dict.has(hash)
}

let getUnsafeByHash = (self: t<'key, 'val>, hash) => {
  self.dict->Js.Dict.unsafeGet(hash)
}

let get = (self: t<'key, 'val>, key: 'key) =>
  self.dict->Utils.Dict.dangerouslyGetNonOption(key->self.hash)

let values = (self: t<'key, 'val>) => self.dict->Js.Dict.values

let clone = (self: t<'key, 'val>) => {
  ...self,
  dict: self.dict->Lodash.cloneDeep,
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
          } else {
            relatedEntityIds->Utils.Set.delete(Entities.getEntityIdUnsafe(entity))->ignore
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
    ~shouldSaveHistory,
    ~containsRollbackDiffChange=false,
  ) => {
    //New entity row with only the latest update
    @inline
    let newEntityRow = () => Types.Updated({
      latest: entityUpdate,
      history: shouldSaveHistory ? [entityUpdate] : [],
      // For new entities, apply "containsRollbackDiffChange" from param
      containsRollbackDiffChange,
    })

    let {entityRow, entityIndices} = switch inMemTable.table->get(entityUpdate.entityId) {
    | None => {entityRow: newEntityRow(), entityIndices: Utils.Set.make()}
    | Some({entityRow: InitialReadFromDb(_), entityIndices}) => {
        entityRow: newEntityRow(),
        entityIndices,
      }
    | Some({entityRow: Updated(previous_values), entityIndices})
      // This prevents two db actions in the same event on the same entity from being recorded to the history table.
      if shouldSaveHistory &&
      previous_values.latest.eventIdentifier == entityUpdate.eventIdentifier =>
      let entityRow = Types.Updated({
        latest: entityUpdate,
        history: previous_values.history->Utils.Array.setIndexImmutable(
          previous_values.history->Array.length - 1,
          entityUpdate,
        ),
        // For updated entities, apply "containsRollbackDiffChange" from previous values
        // (so that the first change if from a rollback diff applies throughout the batch)
        containsRollbackDiffChange: previous_values.containsRollbackDiffChange,
      })
      {entityRow, entityIndices}
    | Some({entityRow: Updated(previous_values), entityIndices}) =>
      let entityRow = Types.Updated({
        latest: entityUpdate,
        history: shouldSaveHistory
          ? [...previous_values.history, entityUpdate]
          : previous_values.history,
        // For updated entities, apply "containsRollbackDiffChange" from previous values
        // (so that the first change if from a rollback diff applies throughout the batch)
        containsRollbackDiffChange: previous_values.containsRollbackDiffChange,
      })
      {entityRow, entityIndices}
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
  let getUnsafe = (inMemTable: t<'entity>) => (key: Types.id) =>
    inMemTable.table.dict
    ->Js.Dict.unsafeGet(key)
    ->rowToEntity

  let hasIndex = (
    inMemTable: t<'entity>,
    ~fieldName,
    ~operator: TableIndices.Operator.t,
  ) => fieldValueHash => {
    switch inMemTable.fieldNameIndices.dict->Utils.Dict.dangerouslyGetNonOption(fieldName) {
    | None => false
    | Some(indicesSerializedToValue) => {
        // Should match TableIndices.toString logic
        let key = `${fieldName}:${(operator :> string)}:${fieldValueHash}`
        indicesSerializedToValue.dict->Utils.Dict.dangerouslyGetNonOption(key) !== None
      }
    }
  }

  let getUnsafeOnIndex = (
    inMemTable: t<'entity>,
    ~fieldName,
    ~operator: TableIndices.Operator.t,
  ) => {
    let getEntity = inMemTable->getUnsafe
    fieldValueHash => {
      switch inMemTable.fieldNameIndices.dict->Utils.Dict.dangerouslyGetNonOption(fieldName) {
      | None => Js.Exn.raiseError(`Unexpected error. Must have an index on field ${fieldName}`)
      | Some(indicesSerializedToValue) => {
          // Should match TableIndices.toString logic
          let key = `${fieldName}:${(operator :> string)}:${fieldValueHash}`
          switch indicesSerializedToValue.dict->Utils.Dict.dangerouslyGetNonOption(key) {
          | None =>
            Js.Exn.raiseError(
              `Unexpected error. Must have an index for the value ${fieldValueHash} on field ${fieldName}`,
            )
          | Some((_index, relatedEntityIds)) => {
              let res =
                relatedEntityIds
                ->Utils.Set.toArray
                ->Array.keepMap(entityId => {
                  switch hasByHash(inMemTable.table, entityId) {
                  | true => getEntity(entityId)
                  | false => None
                  }
                })
              res
            }
          }
        }
      }
    }
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
