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

module Entity = {
  type relatedEntityId = string
  type indexWithRelatedIds = (TableIndices.Index.t, Utils.Set.t<relatedEntityId>)
  type indicesSerializedToValue = t<TableIndices.Index.t, indexWithRelatedIds>
  type indexFieldNameToIndices = t<TableIndices.Index.t, indicesSerializedToValue>

  type entityWithIndices = {
    latest: option<Internal.entity>,
    status: Internal.inMemoryStoreEntityStatus,
    mutable entityIndices?: Utils.Set.t<TableIndices.Index.t>,
  }
  type t = {
    table: t<string, entityWithIndices>,
    fieldNameIndices: indexFieldNameToIndices,
    history: array<Change.t<Internal.entity>>,
  }

  // Helper to extract entity ID from any entity
  exception UnexpectedIdNotDefinedOnEntity
  let getEntityIdUnsafe = (entity: Internal.entity): string =>
    switch (entity->(Utils.magic: Internal.entity => {"id": option<string>}))["id"] {
    | Some(id) => id
    | None =>
      UnexpectedIdNotDefinedOnEntity->ErrorHandling.mkLogAndRaise(
        ~msg="Property 'id' does not exist on expected entity object",
      )
    }

  let getOrCreateEntityIndices = (row: entityWithIndices) =>
    switch row.entityIndices {
    | Some(s) => s
    | None =>
      let s = Utils.Set.make()
      row.entityIndices = Some(s)
      s
    }

  let makeIndicesSerializedToValue = (
    ~index,
    ~relatedEntityIds=Utils.Set.make(),
  ): indicesSerializedToValue => {
    let empty = make(~hash=TableIndices.Index.toString)
    empty->set(index, (index, relatedEntityIds))
    empty
  }

  let make = (): t => {
    table: make(~hash=str => str),
    fieldNameIndices: make(~hash=TableIndices.Index.getFieldName),
    history: [],
  }

  let updateIndices = (self: t, ~entity: Internal.entity, ~row: entityWithIndices) => {
    //Remove any invalid indices on entity
    switch row.entityIndices {
    | None => ()
    | Some(entityIndices) =>
      entityIndices->Utils.Set.forEach(index => {
        let fieldName = index->TableIndices.Index.getFieldName
        let fieldValue =
          entity
          ->(Utils.magic: Internal.entity => dict<TableIndices.FieldValue.t>)
          ->Dict.getUnsafe(fieldName)
        if !(index->TableIndices.Index.evaluate(~fieldName, ~fieldValue)) {
          entityIndices->Utils.Set.delete(index)->ignore
        }
      })
    }

    self.fieldNameIndices.dict
    ->Dict.keysToArray
    ->Array.forEach(fieldName => {
      let indices = self.fieldNameIndices.dict->Dict.getUnsafe(fieldName)
      // A missing key reads as `undefined`, which matches the `None` arm of
      // `FieldValue.t` (`option<...>`). Mirror `addEmptyIndex` so nullable
      // FK columns that were omitted on the set entity don't crash.
      let fieldValue =
        entity
        ->(Utils.magic: Internal.entity => dict<TableIndices.FieldValue.t>)
        ->Dict.getUnsafe(fieldName)
      indices
      ->values
      ->Array.forEach(((index, relatedEntityIds)) => {
        if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
          //Add entity id to indices and add index to entity indicies
          relatedEntityIds->Utils.Set.add(getEntityIdUnsafe(entity))->ignore
          row->getOrCreateEntityIndices->Utils.Set.add(index)->ignore
        } else {
          relatedEntityIds->Utils.Set.delete(getEntityIdUnsafe(entity))->ignore
        }
      })
    })
  }

  let deleteEntityFromIndices = (self: t, ~entityId: string, ~row: entityWithIndices) =>
    switch row.entityIndices {
    | None => ()
    | Some(entityIndices) =>
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
    }

  let initValue = (
    inMemTable: t,
    ~key: string,
    ~entity: option<Internal.entity>,
    // NOTE: This value is only set to true in the internals of the test framework to create the mockDb.
    ~allowOverWriteEntity=false,
  ) => {
    let shouldWriteEntity =
      allowOverWriteEntity ||
      inMemTable.table.dict->Dict.get(key->inMemTable.table.hash)->Option.isNone

    //Only initialize a row in the case where it is none
    //or if allowOverWriteEntity is true (used for mockDb in test helpers)
    if shouldWriteEntity {
      let row: entityWithIndices = {
        latest: entity,
        status: Loaded,
      }
      switch entity {
      | Some(entity) =>
        //update table indices in the case where there
        //is an already set entity
        inMemTable->updateIndices(~entity, ~row)
      | None => ()
      }
      inMemTable.table.dict->Dict.set(key->inMemTable.table.hash, row)
    }
  }

  let setRow = set
  let set = (
    inMemTable: t,
    change: Change.t<Internal.entity>,
    ~containsRollbackDiffChange=false,
  ) => {
    let latest = switch change {
    | Set({entity}) => Some(entity)
    | Delete(_) => None
    }

    let prev = inMemTable.table->get(change->Change.getEntityId)

    let historyIndex = if containsRollbackDiffChange {
      // Rollback-diff replays are restorations from existing history;
      // don't record them again in the in-memory history buffer.
      -1
    } else {
      switch prev {
      | Some({status: Updated(previous_values)})
        if previous_values.historyIndex >= 0 &&
          previous_values.latestChange->Change.getCheckpointId === change->Change.getCheckpointId =>
        inMemTable.history->Array.setUnsafe(previous_values.historyIndex, change)
        previous_values.historyIndex
      | _ =>
        inMemTable.history->Array.push(change)->ignore
        inMemTable.history->Array.length - 1
      }
    }

    let containsRollbackDiffChange = switch prev {
    | Some({status: Updated({containsRollbackDiffChange: prevFlag})}) =>
      prevFlag || containsRollbackDiffChange
    | _ => containsRollbackDiffChange
    }

    let newStatus = Internal.Updated({
      latestChange: change,
      containsRollbackDiffChange,
      historyIndex,
    })

    let updatedEntityRecord: entityWithIndices = switch prev {
    | None => {latest, status: newStatus}
    | Some(prev) => {latest, status: newStatus, entityIndices: ?prev.entityIndices}
    }

    switch change {
    | Set({entity}) => inMemTable->updateIndices(~entity, ~row=updatedEntityRecord)
    | Delete({entityId}) => inMemTable->deleteEntityFromIndices(~entityId, ~row=updatedEntityRecord)
    }
    inMemTable.table->setRow(change->Change.getEntityId, updatedEntityRecord)
  }

  let rowToEntity = row => row.latest

  let getRow = get

  /** It returns option<option<'entity>> where the first option means
  that the entity is not set to the in memory store,
  and the second option means that the entity doesn't esist/deleted.
  It's needed to prevent an additional round trips to the database for deleted entities. */
  let getUnsafe = (inMemTable: t) =>
    (key: string) =>
      inMemTable.table.dict
      ->Dict.getUnsafe(key)
      ->rowToEntity

  let hasIndex = (inMemTable: t, ~fieldName, ~operator: TableIndices.Operator.t) =>
    fieldValueHash => {
      switch inMemTable.fieldNameIndices.dict->Utils.Dict.dangerouslyGetNonOption(fieldName) {
      | None => false
      | Some(indicesSerializedToValue) => {
          // Should match TableIndices.toString logic
          let key = `${fieldName}:${(operator :> string)}:${fieldValueHash}`
          indicesSerializedToValue.dict->Utils.Dict.dangerouslyGetNonOption(key) !== None
        }
      }
    }

  let getUnsafeOnIndex = (inMemTable: t, ~fieldName, ~operator: TableIndices.Operator.t) => {
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

  let addEmptyIndex = (inMemTable: t, ~index) => {
    let fieldName = index->TableIndices.Index.getFieldName
    let relatedEntityIds = Utils.Set.make()

    inMemTable.table
    ->values
    ->Array.forEach(row => {
      switch row->rowToEntity {
      | Some(entity) =>
        let fieldValue =
          entity
          ->(Utils.magic: Internal.entity => dict<TableIndices.FieldValue.t>)
          ->Dict.getUnsafe(fieldName)
        if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
          let _ = row->getOrCreateEntityIndices->Utils.Set.add(index)
          let _ = relatedEntityIds->Utils.Set.add(entity->getEntityIdUnsafe)
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

  let addIdToIndex = (inMemTable: t, ~index, ~entityId) =>
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

  let updates = (inMemTable: t) => {
    inMemTable.table
    ->values
    ->Array.filterMap(v =>
      switch v.status {
      | Updated(update) => Some(update)
      | Loaded => None
      }
    )
  }

  let values = (inMemTable: t) => {
    inMemTable.table
    ->values
    ->Array.filterMap(rowToEntity)
  }
}
