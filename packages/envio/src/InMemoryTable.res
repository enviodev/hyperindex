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
  self.dict->Dict.has(hash)
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
    mutable readCount: float,
  }
  type t = {
    entities: dict<entityWithIndices>,
    fieldNameIndices: indexFieldNameToIndices,
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
    entities: Dict.make(),
    fieldNameIndices: make(~hash=TableIndices.Index.getFieldName),
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
      inMemTable.entities->Utils.Dict.dangerouslyGetNonOption(key)->Option.isNone

    //Only initialize a row in the case where it is none
    //or if allowOverWriteEntity is true (used for mockDb in test helpers)
    if shouldWriteEntity {
      let row: entityWithIndices = {
        latest: entity,
        status: Loaded,
        readCount: 0.,
      }
      switch entity {
      | Some(entity) =>
        //update table indices in the case where there
        //is an already set entity
        inMemTable->updateIndices(~entity, ~row)
      | None => ()
      }
      inMemTable.entities->Dict.set(key, row)
    }
  }

  let setRow = set
  let set = (
    inMemTable: t,
    change: Change.t<Internal.entity>,
    ~shouldSaveHistory,
    ~containsRollbackDiffChange=false,
  ) => {
    //New entity row with only the latest update
    @inline
    let newStatus = () => Internal.Updated({
      latestChange: change,
      history: shouldSaveHistory
        ? [change]
        : Utils.Array.immutableEmpty->(
            Utils.magic: array<unknown> => array<Change.t<Internal.entity>>
          ),
      containsRollbackDiffChange,
    })
    let latest = switch change {
    | Set({entity}) => Some(entity)
    | Delete(_) => None
    }

    let updatedEntityRecord: entityWithIndices = switch inMemTable.entities->Utils.Dict.dangerouslyGetNonOption(
      change->Change.getEntityId,
    ) {
    | None => {latest, status: newStatus(), readCount: 0.}
    | Some(prev) =>
      switch prev.status {
      | Loaded => {
          latest,
          status: newStatus(),
          entityIndices: ?prev.entityIndices,
          readCount: prev.readCount,
        }
      | Updated(previous_values) =>
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
        {
          latest,
          status: newStatus,
          entityIndices: ?prev.entityIndices,
          readCount: prev.readCount,
        }
      }
    }

    switch change {
    | Set({entity}) => inMemTable->updateIndices(~entity, ~row=updatedEntityRecord)
    | Delete({entityId}) => inMemTable->deleteEntityFromIndices(~entityId, ~row=updatedEntityRecord)
    }
    inMemTable.entities->Dict.set(change->Change.getEntityId, updatedEntityRecord)
  }

  let rowToEntity = row => row.latest

  let getRow = get

  /** It returns option<option<'entity>> where the first option means
  that the entity is not set to the in memory store,
  and the second option means that the entity doesn't esist/deleted.
  It's needed to prevent an additional round trips to the database for deleted entities. */
  let getUnsafe = (inMemTable: t) =>
    (key: string) =>
      inMemTable.entities
      ->Dict.getUnsafe(key)
      ->rowToEntity

  let incrementReadCount = (inMemTable: t, ~entityId: string) =>
    switch inMemTable.entities->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | Some(row) => row.readCount = row.readCount +. 1.
    | None => ()
    }

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
                  switch inMemTable.entities->Dict.has(entityId) {
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

    inMemTable.entities->Utils.Dict.forEach(row => {
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
    let acc = []
    inMemTable.entities->Utils.Dict.forEach(v =>
      switch v.status {
      | Updated(update) => acc->Array.push(update)
      | Loaded => ()
      }
    )
    acc
  }

  let values = (inMemTable: t) => {
    let acc = []
    inMemTable.entities->Utils.Dict.forEach(v =>
      switch v->rowToEntity {
      | Some(entity) => acc->Array.push(entity)
      | None => ()
      }
    )
    acc
  }
}
