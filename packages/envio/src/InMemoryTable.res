module Entity = {
  type relatedEntityId = string
  type indexWithRelatedIds = (TableIndices.Index.t, Utils.Set.t<relatedEntityId>)
  // Keyed by TableIndices.Index.toString
  type indicesSerializedToValue = dict<indexWithRelatedIds>
  // Keyed by TableIndices.Index.getFieldName
  type indexFieldNameToIndices = dict<indicesSerializedToValue>

  type entityIndices = Utils.Set.t<TableIndices.Index.t>
  type t = {
    latestEntityChangeById: dict<Change.t<Internal.entity>>,
    // Counts every recorded change (new latest ids and pushes to
    // prevEntityChanges), kept in sync manually so InMemoryStore can gauge the
    // store size without scanning every dict.
    mutable changesCount: float,
    // Swapped out wholesale when a write starts so processing can keep appending
    // while the previous changes are persisted in the background.
    mutable prevEntityChanges: array<Change.t<Internal.entity>>,
    mutable indicesByEntityId: dict<entityIndices>,
    mutable fieldNameIndices: indexFieldNameToIndices,
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

  let getOrCreateEntityIndices = (self: t, ~entityId) =>
    switch self.indicesByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | Some(s) => s
    | None =>
      let s = Utils.Set.make()
      self.indicesByEntityId->Dict.set(entityId, s)
      s
    }

  let makeIndicesSerializedToValue = (
    ~index,
    ~relatedEntityIds=Utils.Set.make(),
  ): indicesSerializedToValue => {
    let empty = Dict.make()
    empty->Dict.set(index->TableIndices.Index.toString, (index, relatedEntityIds))
    empty
  }

  let make = (): t => {
    latestEntityChangeById: Dict.make(),
    changesCount: 0.,
    prevEntityChanges: [],
    indicesByEntityId: Dict.make(),
    fieldNameIndices: Dict.make(),
  }

  // Drops the per-batch index state and rollback history, but keeps the
  // already committed entities so the next batch can read them without
  // hitting the database.
  let resetButKeepLatestChanges = (self: t): t => {
    ...make(),
    latestEntityChangeById: self.latestEntityChangeById,
    // writeBatch already mutated this to subtract the dropped prevEntityChanges.
    changesCount: self.changesCount,
  }

  // Like resetButKeepLatestChanges, but only keeps entities loaded from the db
  // (changes carrying loadedFromDbCheckpointId), dropping everything written in
  // a batch. The kept count is exposed through the table's changesCount.
  let resetButKeepLoadedFromDbChanges = (self: t): t => {
    let latestEntityChangeById = Dict.make()
    let keptCount = ref(0.)
    self.latestEntityChangeById->Utils.Dict.forEachWithKey((change, key) =>
      if change->Change.getCheckpointId === Internal.loadedFromDbCheckpointId {
        latestEntityChangeById->Dict.set(key, change)
        keptCount := keptCount.contents +. 1.
      }
    )
    {
      ...make(),
      latestEntityChangeById,
      changesCount: keptCount.contents,
    }
  }

  // Pull out the changes that need to be persisted for checkpoints above
  // committedCheckpointId. Reuses prevEntityChanges as the write buffer and
  // installs a fresh one, so concurrent processing keeps accumulating into the
  // table while these changes are written to the db in the background.
  let snapshotChanges = (self: t, ~committedCheckpointId): array<Change.t<Internal.entity>> => {
    let changes = self.prevEntityChanges
    self.prevEntityChanges = []
    self.changesCount = self.changesCount -. changes->Array.length->Int.toFloat
    self.latestEntityChangeById->Utils.Dict.forEach(change =>
      if change->Change.getCheckpointId > committedCheckpointId {
        changes->Array.push(change)
      }
    )
    changes
  }

  // Free memory held by changes already committed to the db: drop every latest
  // entry at or below committedCheckpointId (re-readable from the db) and clear
  // the per-batch indices so they get rebuilt on the next getWhere. Uncommitted
  // changes (checkpointId > committedCheckpointId) must be kept.
  let dropCommittedChanges = (self: t, ~committedCheckpointId) => {
    let keysToDelete = []
    self.latestEntityChangeById->Utils.Dict.forEachWithKey((change, key) =>
      if !(change->Change.getCheckpointId > committedCheckpointId) {
        keysToDelete->Array.push(key)
      }
    )
    keysToDelete->Array.forEach(key => self.latestEntityChangeById->Utils.Dict.deleteInPlace(key))
    self.changesCount = self.changesCount -. keysToDelete->Array.length->Int.toFloat
    self.indicesByEntityId = Dict.make()
    self.fieldNameIndices = Dict.make()
  }

  let updateIndices = (self: t, ~entity: Internal.entity) => {
    let entityId = entity->getEntityIdUnsafe
    //Remove any invalid indices on entity
    switch self.indicesByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
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

    self.fieldNameIndices->Utils.Dict.forEachWithKey((indices, fieldName) => {
      // A missing key reads as `undefined`, which matches the `None` arm of
      // `FieldValue.t` (`option<...>`). Mirror `addEmptyIndex` so nullable
      // FK columns that were omitted on the set entity don't crash.
      let fieldValue =
        entity
        ->(Utils.magic: Internal.entity => dict<TableIndices.FieldValue.t>)
        ->Dict.getUnsafe(fieldName)
      indices->Utils.Dict.forEach(((index, relatedEntityIds)) => {
        if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
          //Add entity id to indices and add index to entity indicies
          relatedEntityIds->Utils.Set.add(entityId)->ignore
          self->getOrCreateEntityIndices(~entityId)->Utils.Set.add(index)->ignore
        } else {
          relatedEntityIds->Utils.Set.delete(entityId)->ignore
        }
      })
    })
  }

  let deleteEntityFromIndices = (self: t, ~entityId: string) =>
    switch self.indicesByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | None => ()
    | Some(entityIndices) =>
      entityIndices->Utils.Set.forEach(index => {
        switch self.fieldNameIndices
        ->Utils.Dict.dangerouslyGetNonOption(index->TableIndices.Index.getFieldName)
        ->Option.flatMap(indices =>
          indices->Utils.Dict.dangerouslyGetNonOption(index->TableIndices.Index.toString)
        ) {
        | Some((_index, relatedEntityIds)) =>
          let _wasRemoved = relatedEntityIds->Utils.Set.delete(entityId)
        | None => () //Unexpected index should exist if it is entityIndices
        }
        let _wasRemoved = entityIndices->Utils.Set.delete(index)
      })
    }

  let set = (inMemTable: t, ~committedCheckpointId, change: Change.t<Internal.entity>) => {
    let entityId = change->Change.getEntityId
    switch inMemTable.latestEntityChangeById->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | Some(prev) =>
      let prevCheckpointId = prev->Change.getCheckpointId
      if (
        prevCheckpointId > committedCheckpointId &&
          prevCheckpointId < change->Change.getCheckpointId
      ) {
        inMemTable.prevEntityChanges->Array.push(prev)
        inMemTable.changesCount = inMemTable.changesCount +. 1.
      }
    | None => inMemTable.changesCount = inMemTable.changesCount +. 1.
    }

    switch change {
    | Set({entity}) => inMemTable->updateIndices(~entity)
    | Delete({entityId}) => inMemTable->deleteEntityFromIndices(~entityId)
    }
    inMemTable.latestEntityChangeById->Dict.set(entityId, change)
  }

  // Only writes when the id isn't already present, so set always takes its
  // None branch here (committedCheckpointId is never read).
  let initValue = (
    inMemTable: t,
    ~committedCheckpointId,
    ~key: string,
    ~entity: option<Internal.entity>,
  ) =>
    if inMemTable.latestEntityChangeById->Utils.Dict.dangerouslyGetNonOption(key)->Option.isNone {
      let change: Change.t<Internal.entity> = switch entity {
      | Some(entity) =>
        Set({entityId: key, entity, checkpointId: Internal.loadedFromDbCheckpointId})
      | None => Delete({entityId: key, checkpointId: Internal.loadedFromDbCheckpointId})
      }
      inMemTable->set(~committedCheckpointId, change)
    }

  let mapChangeToEntity = (change: Change.t<Internal.entity>) =>
    switch change {
    | Set({entity}) => Some(entity)
    | Delete(_) => None
    }

  /** It returns option<option<'entity>> where the first option means
  that the entity is not set to the in memory store,
  and the second option means that the entity doesn't esist/deleted.
  It's needed to prevent an additional round trips to the database for deleted entities. */
  let getUnsafe = (inMemTable: t) =>
    (key: string) =>
      inMemTable.latestEntityChangeById
      ->Dict.getUnsafe(key)
      ->mapChangeToEntity

  let hasIndex = (inMemTable: t, ~fieldName, ~operator: TableIndices.Operator.t) =>
    fieldValueHash => {
      switch inMemTable.fieldNameIndices->Utils.Dict.dangerouslyGetNonOption(fieldName) {
      | None => false
      | Some(indicesSerializedToValue) => {
          let key = TableIndices.Index.toStringByParts(~fieldName, ~operator, ~fieldValueHash)
          indicesSerializedToValue->Utils.Dict.dangerouslyGetNonOption(key) !== None
        }
      }
    }

  let getUnsafeOnIndex = (inMemTable: t, ~fieldName, ~operator: TableIndices.Operator.t) => {
    let getEntity = inMemTable->getUnsafe
    fieldValueHash => {
      switch inMemTable.fieldNameIndices->Utils.Dict.dangerouslyGetNonOption(fieldName) {
      | None =>
        JsError.throwWithMessage(`Unexpected error. Must have an index on field ${fieldName}`)
      | Some(indicesSerializedToValue) => {
          let key = TableIndices.Index.toStringByParts(~fieldName, ~operator, ~fieldValueHash)
          switch indicesSerializedToValue->Utils.Dict.dangerouslyGetNonOption(key) {
          | None =>
            JsError.throwWithMessage(
              `Unexpected error. Must have an index for the value ${fieldValueHash} on field ${fieldName}`,
            )
          | Some((_index, relatedEntityIds)) => {
              let res =
                relatedEntityIds
                ->Utils.Set.toArray
                ->Array.filterMap(entityId => {
                  switch inMemTable.latestEntityChangeById->Dict.has(entityId) {
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

    inMemTable.latestEntityChangeById->Utils.Dict.forEach(change => {
      switch change->mapChangeToEntity {
      | Some(entity) =>
        let fieldValue =
          entity
          ->(Utils.magic: Internal.entity => dict<TableIndices.FieldValue.t>)
          ->Dict.getUnsafe(fieldName)
        if index->TableIndices.Index.evaluate(~fieldName, ~fieldValue) {
          let entityId = entity->getEntityIdUnsafe
          let _ = inMemTable->getOrCreateEntityIndices(~entityId)->Utils.Set.add(index)
          let _ = relatedEntityIds->Utils.Set.add(entityId)
        }
      | None => ()
      }
    })
    switch inMemTable.fieldNameIndices->Utils.Dict.dangerouslyGetNonOption(fieldName) {
    | None =>
      inMemTable.fieldNameIndices->Dict.set(
        fieldName,
        makeIndicesSerializedToValue(~index, ~relatedEntityIds),
      )
    | Some(indicesSerializedToValue) =>
      switch indicesSerializedToValue->Utils.Dict.dangerouslyGetNonOption(
        index->TableIndices.Index.toString,
      ) {
      | None =>
        indicesSerializedToValue->Dict.set(
          index->TableIndices.Index.toString,
          (index, relatedEntityIds),
        )
      | Some(_) => () //Should not happen, this means the index already exists
      }
    }
  }
}
