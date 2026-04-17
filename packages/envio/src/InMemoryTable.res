type t<'key, 'val> = {
  dict: dict<'val>,
  hash: 'key => string,
}

let make = (~hash): t<'key, 'val> => {
  dict: Dict.make(),
  hash,
}

let set = (self: t<'key, 'val>, key, value) => self.dict->Dict.set(key->self.hash, value)

let setByHash = (self: t<'key, 'val>, hash, value) => self.dict->Dict.set(hash, value)

let hasByHash = (self: t<'key, 'val>, hash) => {
  self.dict->Utils.Dict.has(hash)
}

let getUnsafeByHash = (self: t<'key, 'val>, hash) => {
  self.dict->Dict.getUnsafe(hash)
}

let get = (self: t<'key, 'val>, key: 'key) =>
  self.dict->Utils.Dict.dangerouslyGetNonOption(key->self.hash)

let values = (self: t<'key, 'val>) => self.dict->Dict.valuesToArray

let clone = (self: t<'key, 'val>) => {
  ...self,
  dict: self.dict->Lodash.cloneDeep,
}

module Entity = {
  type relatedEntityId = string
  type indexWithRelatedIds = (TableIndices.Index.t, Utils.Set.t<relatedEntityId>)
  type indicesSerializedToValue = t<TableIndices.Index.t, indexWithRelatedIds>
  type indexFieldNameToIndices = t<TableIndices.Index.t, indicesSerializedToValue>

  type entityWithIndices<'entity> = {
    latest: option<'entity>,
    status: Internal.inMemoryStoreEntityStatus<'entity>,
    entityIndices: Utils.Set.t<TableIndices.Index.t>,
  }
  // Flat (fieldName, index, relatedEntityIds) tuple kept in sync with
  // fieldNameIndices so updateIndices can iterate without allocating
  // a keys array on every Entity.set.
  type indexEntry = {
    fieldName: string,
    index: TableIndices.Index.t,
    relatedEntityIds: Utils.Set.t<relatedEntityId>,
  }
  type t<'entity> = {
    table: t<string, entityWithIndices<'entity>>,
    fieldNameIndices: indexFieldNameToIndices,
    allIndices: array<indexEntry>,
  }

  // Helper to extract entity ID from any entity
  exception UnexpectedIdNotDefinedOnEntity
  let getEntityIdUnsafe = (entity: 'entity): string =>
    switch (entity->(Utils.magic: 'entity => {"id": option<string>}))["id"] {
    | Some(id) => id
    | None =>
      UnexpectedIdNotDefinedOnEntity->ErrorHandling.mkLogAndRaise(
        ~msg="Property 'id' does not exist on expected entity object",
      )
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
    allIndices: [],
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
        ->Dict.get(fieldName)
        ->Option.getUnsafe
      if !(index->TableIndices.Index.evaluate(~fieldName, ~fieldValue)) {
        entityIndices->Utils.Set.delete(index)->ignore
      }
    })

    let allIndices = self.allIndices
    let allIndicesLength = allIndices->Array.length
    if allIndicesLength > 0 {
      let entityDict = entity->(Utils.magic: 'entity => dict<TableIndices.FieldValue.t>)
      let entityId = getEntityIdUnsafe(entity)
      for i in 0 to allIndicesLength - 1 {
        let {fieldName, index, relatedEntityIds} = allIndices->Array.getUnsafe(i)
        switch entityDict->Dict.get(fieldName) {
        | Some(fieldValue) =>
          if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
            //Add entity id to indices and add index to entity indicies
            relatedEntityIds->Utils.Set.add(entityId)->ignore
            entityIndices->Utils.Set.add(index)->ignore
          } else {
            relatedEntityIds->Utils.Set.delete(entityId)->ignore
          }
        | None =>
          UndefinedKey(fieldName)->ErrorHandling.mkLogAndRaise(
            ~msg="Expected field name to exist on the referenced index and the provided entity",
          )
        }
      }
    }
  }

  let deleteEntityFromIndices = (self: t<'entity>, ~entityId: string, ~entityIndices) =>
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
    ~key: string,
    ~entity: option<'entity>,
    // NOTE: This value is only set to true in the internals of the test framework to create the mockDb.
    ~allowOverWriteEntity=false,
  ) => {
    let shouldWriteEntity =
      allowOverWriteEntity ||
      inMemTable.table.dict->Dict.get(key->inMemTable.table.hash)->Option.isNone

    //Only initialize a row in the case where it is none
    //or if allowOverWriteEntity is true (used for mockDb in test helpers)
    if shouldWriteEntity {
      let entityIndices = Utils.Set.make()
      switch entity {
      | Some(entity) =>
        //update table indices in the case where there
        //is an already set entity
        inMemTable->updateIndices(~entity, ~entityIndices)
      | None => ()
      }
      inMemTable.table.dict->Dict.set(
        key->inMemTable.table.hash,
        {
          latest: entity,
          status: Loaded,
          entityIndices,
        },
      )
    }
  }

  let setRow = set
  let set = (
    inMemTable: t<'entity>,
    change: Change.t<'entity>,
    ~shouldSaveHistory,
    ~containsRollbackDiffChange=false,
  ) => {
    //New entity row with only the latest update
    @inline
    let newStatus = () => Internal.Updated({
      latestChange: change,
      history: shouldSaveHistory
        ? [change]
        : Utils.Array.immutableEmpty->(Utils.magic: array<unknown> => array<Change.t<'entity>>),
      containsRollbackDiffChange,
    })
    let latest = switch change {
    | Set({entity}) => Some(entity)
    | Delete(_) => None
    }

    let updatedEntityRecord = switch inMemTable.table->get(change->Change.getEntityId) {
    | None => {latest, status: newStatus(), entityIndices: Utils.Set.make()}
    | Some({status: Loaded, entityIndices}) => {
        latest,
        status: newStatus(),
        entityIndices,
      }
    | Some({status: Updated(previous_values), entityIndices}) =>
      let newStatus = Internal.Updated({
        latestChange: change,
        history: switch shouldSaveHistory {
        // This prevents two db actions in the same event on the same entity from being recorded to the history table.
        | true
          if previous_values.latestChange->Change.getCheckpointId ===
            change->Change.getCheckpointId =>
          previous_values.history->Utils.Array.setIndexImmutable(
            previous_values.history->Array.length - 1,
            change,
          )
        | true => [...previous_values.history, change]
        | false => previous_values.history
        },
        containsRollbackDiffChange: previous_values.containsRollbackDiffChange,
      })
      {latest, status: newStatus, entityIndices}
    }

    switch change {
    | Set({entity}) =>
      inMemTable->updateIndices(~entity, ~entityIndices=updatedEntityRecord.entityIndices)
    | Delete({entityId}) =>
      inMemTable->deleteEntityFromIndices(
        ~entityId,
        ~entityIndices=updatedEntityRecord.entityIndices,
      )
    }
    inMemTable.table->setRow(change->Change.getEntityId, updatedEntityRecord)
  }

  let rowToEntity = row => row.latest

  let getRow = get

  /** It returns option<option<'entity>> where the first option means
  that the entity is not set to the in memory store,
  and the second option means that the entity doesn't esist/deleted.
  It's needed to prevent an additional round trips to the database for deleted entities. */
  let getUnsafe = (inMemTable: t<'entity>) => (key: string) =>
    inMemTable.table.dict
    ->Dict.getUnsafe(key)
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
      | None =>
        JsError.throwWithMessage(`Unexpected error. Must have an index on field ${fieldName}`)
      | Some(indicesSerializedToValue) => {
          // Should match TableIndices.toString logic
          let key = `${fieldName}:${(operator :> string)}:${fieldValueHash}`
          switch indicesSerializedToValue.dict->Utils.Dict.dangerouslyGetNonOption(key) {
          | None =>
            JsError.throwWithMessage(
              `Unexpected error. Must have an index for the value ${fieldValueHash} on field ${fieldName}`,
            )
          | Some((_index, relatedEntityIds)) => {
              let res =
                relatedEntityIds
                ->Utils.Set.toArray
                ->Array.filterMap(entityId => {
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
          ->Dict.getUnsafe(fieldName)
        if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
          let _ = row.entityIndices->Utils.Set.add(index)
          let _ = relatedEntityIds->Utils.Set.add(entity->getEntityIdUnsafe)
        }
      | None => ()
      }
    })
    let isNewIndex = switch inMemTable.fieldNameIndices->getRow(index) {
    | None =>
      inMemTable.fieldNameIndices->setRow(
        index,
        makeIndicesSerializedToValue(~index, ~relatedEntityIds),
      )
      true
    | Some(indicesSerializedToValue) =>
      switch indicesSerializedToValue->getRow(index) {
      | None =>
        indicesSerializedToValue->setRow(index, (index, relatedEntityIds))
        true
      | Some(_) => false //Should not happen, this means the index already exists
      }
    }
    if isNewIndex {
      inMemTable.allIndices->Array.push({fieldName, index, relatedEntityIds})->ignore
    }
  }

  let updates = (inMemTable: t<'entity>) => {
    inMemTable.table
    ->values
    ->Array.filterMap(v =>
      switch v.status {
      | Updated(update) => Some(update)
      | Loaded => None
      }
    )
  }

  let values = (inMemTable: t<'entity>) => {
    inMemTable.table
    ->values
    ->Array.filterMap(rowToEntity)
  }

  let clone = ({table, fieldNameIndices}: t<'entity>) => {
    let clonedFieldNameIndices = {
      ...fieldNameIndices,
      dict: fieldNameIndices.dict
      ->Dict.toArray
      ->Array.map(((k, v)) => (k, v->clone))
      ->Dict.fromArray,
    }
    // Rebuild the flat allIndices cache from the cloned (deep-copied) sets
    // so rollback paths have the same O(1)-lookup structure as a live table.
    let allIndices = []
    clonedFieldNameIndices.dict->Utils.Dict.forEach(indicesSerializedToValue => {
      indicesSerializedToValue.dict->Utils.Dict.forEach(((index, relatedEntityIds)) => {
        allIndices
        ->Array.push({
          fieldName: index->TableIndices.Index.getFieldName,
          index,
          relatedEntityIds,
        })
        ->ignore
      })
    })
    {
      table: table->clone,
      fieldNameIndices: clonedFieldNameIndices,
      allIndices,
    }
  }
}
