module Entity = {
  type relatedEntityId = string
  // The matcher is specialized from the filter once at index creation and
  // reused for every entity write against this index.
  type index = {
    matcher: EntityFilter.matcher,
    ids: Utils.Set.t<relatedEntityId>,
  }

  // Indexes on one field that a single value can resolve — _eq, and _in under
  // each of its values — found by the field's value rather than by running
  // their matchers, so a write costs a lookup per indexed field instead of a
  // pass over every registered index. Several indexes can share a value: an
  // _in and an _eq naming it, or two _in filters overlapping on it.
  type eqBucket = {
    keyOf: unknown => unknown,
    byValue: Utils.Map.t<unknown, array<index>>,
    // Scan the warm rows once per field, then seed new filters from its values.
    entityIdsByValue: Utils.Map.t<unknown, Utils.Set.t<string>>,
    // Remember the key for removal before a later explicit set.
    valueByEntityId: dict<unknown>,
    // Values a completed query has already loaded every row for. A later
    // filter naming only these is answered from the table instead of a
    // second round trip for rows that are already in it.
    loadedValues: Utils.Set.t<unknown>,
  }

  type t = {
    // Keys every id dict and Set below; see Table.table.
    entityIdToKey: EntityId.t => string,
    latestEntityChangeById: dict<Change.t<Internal.entity>>,
    // Recorded changes (new latest ids + prevEntityChanges pushes), tracked
    // manually so InMemoryStore can gauge size without scanning every dict.
    mutable changesCount: float,
    // Ids set since the last snapshot, so a write reads its changes without
    // scanning every entity the table keeps warm.
    mutable dirtyIds: Utils.Set.t<string>,
    // Swapped out when a write starts so processing keeps appending while the
    // previous changes persist in the background.
    mutable prevEntityChanges: array<Change.t<Internal.entity>>,
    // Every index an entity currently belongs to, so a write can drop it from
    // the ones it stopped matching without consulting the others.
    mutable indexesByEntityId: dict<Utils.Set.t<index>>,
    // Keyed by EntityFilter.toString, for lookups coming from the load manager.
    mutable indexesByKey: dict<index>,
    mutable eqBucketsByField: dict<eqBucket>,
    // Ranges and composites, which no single field value can resolve.
    mutable scanIndexes: array<index>,
    // Lets a write skip index upkeep when no getWhere has built one, the common
    // case, without probing the index maps.
    mutable hasIndexes: bool,
  }

  let getEntityKeyUnsafe = (self: t, entity: Internal.entity): string =>
    switch (entity->(Utils.magic: Internal.entity => {"id": option<EntityId.t>}))["id"] {
    | Some(id) => self.entityIdToKey(id)
    | None => JsError.throwWithMessage("Property 'id' does not exist on expected entity object")
    }

  let addToIndex = (self: t, ~index: index, ~entityId) => {
    index.ids->Utils.Set.add(entityId)->ignore
    switch self.indexesByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | Some(indexes) => indexes->Utils.Set.add(index)->ignore
    | None => self.indexesByEntityId->Dict.set(entityId, Utils.Set.fromArray([index]))
    }
  }

  let removeFromEqBucket = (bucket: eqBucket, entityId) =>
    switch bucket.valueByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | None => ()
    | Some(valueKey) =>
      switch bucket.entityIdsByValue->Utils.Map.get(valueKey) {
      | None => ()
      | Some(ids) =>
        ids->Utils.Set.delete(entityId)->ignore
        if ids->Utils.Set.size == 0 {
          bucket.entityIdsByValue->Utils.Map.delete(valueKey)->ignore
        }
      }
      bucket.valueByEntityId->Utils.Dict.deleteInPlace(entityId)
    }

  let addToEqBucket = (bucket: eqBucket, ~entityId, fieldValue) =>
    if !(fieldValue->EntityFilter.nullish) {
      let valueKey = bucket.keyOf(fieldValue)
      bucket.valueByEntityId->Dict.set(entityId, valueKey)
      switch bucket.entityIdsByValue->Utils.Map.get(valueKey) {
      | Some(ids) => ids->Utils.Set.add(entityId)->ignore
      | None =>
        bucket.entityIdsByValue->Utils.Map.set(valueKey, Utils.Set.fromArray([entityId]))->ignore
      }
    }

  let make = (~entityIdToKey): t => {
    entityIdToKey,
    latestEntityChangeById: Dict.make(),
    changesCount: 0.,
    dirtyIds: Utils.Set.make(),
    prevEntityChanges: [],
    indexesByEntityId: Dict.make(),
    indexesByKey: Dict.make(),
    eqBucketsByField: Dict.make(),
    scanIndexes: [],
    hasIndexes: false,
  }

  // Changes to persist for checkpoints in (committedCheckpointId, upToCheckpointId].
  // Those above upToCheckpointId stay in the table for a later write, while
  // concurrent processing keeps accumulating.
  let snapshotChanges = (self: t, ~committedCheckpointId, ~upToCheckpointId): array<
    Change.t<Internal.entity>,
  > => {
    let changes = []
    let keptPrev = []
    self.prevEntityChanges->Array.forEach(change => {
      let checkpointId = change->Change.getCheckpointId
      if checkpointId > upToCheckpointId {
        keptPrev->Array.push(change)
      } else if checkpointId > committedCheckpointId {
        changes->Array.push(change)
      }
      // Drop changes at or below committedCheckpointId: they were already
      // snapshotted by the write that committed them. They land here when an
      // entity is overwritten while that write is still in flight — set's
      // guard compares against the not-yet-advanced committed checkpoint —
      // and re-emitting them would write duplicate history rows.
    })
    let removedCount = self.prevEntityChanges->Array.length - keptPrev->Array.length
    self.prevEntityChanges = keptPrev
    self.changesCount = self.changesCount -. removedCount->Int.toFloat
    // An id whose latest change is above upToCheckpointId stays dirty for a
    // later write; the rest leave the set whether or not they're emitted.
    let keptDirty = Utils.Set.make()
    self.dirtyIds->Utils.Set.forEach(id =>
      switch self.latestEntityChangeById->Utils.Dict.dangerouslyGetNonOption(id) {
      | Some(change) =>
        let checkpointId = change->Change.getCheckpointId
        if checkpointId > upToCheckpointId {
          keptDirty->Utils.Set.add(id)->ignore
        } else if checkpointId > committedCheckpointId {
          changes->Array.push(change)
        }
      | None => ()
      }
    )
    self.dirtyIds = keptDirty
    changes
  }

  // Frees committed changes: drops latest entries at or below committedCheckpointId
  // (re-readable from the db) and clears the per-batch indexes (rebuilt on the next
  // getWhere). Uncommitted changes are kept. With keepLoadedFromDb, entries seeded
  // from a db read are spared so the cheaper-to-re-derive writes are dropped first.
  let dropCommittedChanges = (self: t, ~committedCheckpointId, ~keepLoadedFromDb) => {
    let keysToDelete = []
    self.latestEntityChangeById->Utils.Dict.forEachWithKey((change, key) => {
      let checkpointId = change->Change.getCheckpointId
      if (
        !(checkpointId > committedCheckpointId) &&
        !(keepLoadedFromDb && checkpointId == Internal.loadedFromDbCheckpointId)
      ) {
        keysToDelete->Array.push(key)
      }
    })
    keysToDelete->Array.forEach(key => self.latestEntityChangeById->Utils.Dict.deleteInPlace(key))
    self.changesCount = self.changesCount -. keysToDelete->Array.length->Int.toFloat
    self.indexesByEntityId = Dict.make()
    self.indexesByKey = Dict.make()
    self.eqBucketsByField = Dict.make()
    self.scanIndexes = []
    self.hasIndexes = false
  }

  let updateIndexes = (self: t, ~entityId: string, ~entity: Internal.entity) =>
    if self.hasIndexes {
      switch self.indexesByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
      | None => ()
      | Some(indexes) =>
        indexes->Utils.Set.forEach(index =>
          if !index.matcher(entity) {
            index.ids->Utils.Set.delete(entityId)->ignore
            indexes->Utils.Set.delete(index)->ignore
          }
        )
      }

      self.eqBucketsByField->Utils.Dict.forEachWithKey((bucket, fieldName) => {
        let fieldValue = entity->EntityFilter.getField(fieldName)
        bucket->removeFromEqBucket(entityId)
        bucket->addToEqBucket(~entityId, fieldValue)

        // A nullish column matches no equality index, and the key projections
        // would throw on it.
        if !(fieldValue->EntityFilter.nullish) {
          switch bucket.byValue->Utils.Map.get(bucket.keyOf(fieldValue)) {
          | Some(indexes) => indexes->Array.forEach(index => self->addToIndex(~index, ~entityId))
          | None => ()
          }
        }
      })

      self.scanIndexes->Array.forEach(index =>
        if index.matcher(entity) {
          self->addToIndex(~index, ~entityId)
        }
      )
    }

  let deleteEntityFromIndexes = (self: t, ~entityId: string) => {
    self.eqBucketsByField->Utils.Dict.forEach(bucket => bucket->removeFromEqBucket(entityId))
    switch self.indexesByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | None => ()
    | Some(indexes) =>
      indexes->Utils.Set.forEach(index => index.ids->Utils.Set.delete(entityId)->ignore)
      self.indexesByEntityId->Utils.Dict.deleteInPlace(entityId)
    }
  }

  // Snapshot the readonly top-level record so changing the caller's object
  // cannot silently invalidate scalar buckets. Nested objects remain live and
  // use the existing scan path; freezing a Date would not freeze its time.
  let snapshotEntity: Internal.entity => Internal.entity = %raw(`entity => Object.freeze({...entity})`)

  let set = (inMemTable: t, ~committedCheckpointId, change: Change.t<Internal.entity>) => {
    let change: Change.t<Internal.entity> = switch change {
    | Set({entityId, entity, checkpointId}) =>
      Set({entityId, entity: snapshotEntity(entity), checkpointId})
    | Delete(_) => change
    }
    let entityKey = inMemTable.entityIdToKey(change->Change.getEntityId)
    switch inMemTable.latestEntityChangeById->Utils.Dict.dangerouslyGetNonOption(entityKey) {
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
    | Set({entity}) => inMemTable->updateIndexes(~entityId=entityKey, ~entity)
    | Delete(_) => inMemTable->deleteEntityFromIndexes(~entityId=entityKey)
    }
    inMemTable.latestEntityChangeById->Dict.set(entityKey, change)
    if change->Change.getCheckpointId > committedCheckpointId {
      inMemTable.dirtyIds->Utils.Set.add(entityKey)->ignore
    }
  }

  // Only writes when the id isn't already present, so set always takes its
  // None branch here (committedCheckpointId is never read).
  let initValue = (
    inMemTable: t,
    ~committedCheckpointId,
    ~entityId: EntityId.t,
    ~entity: option<Internal.entity>,
  ) =>
    if (
      inMemTable.latestEntityChangeById
      ->Utils.Dict.dangerouslyGetNonOption(inMemTable.entityIdToKey(entityId))
      ->Option.isNone
    ) {
      let change: Change.t<Internal.entity> = switch entity {
      | Some(entity) => Set({entityId, entity, checkpointId: Internal.loadedFromDbCheckpointId})
      | None => Delete({entityId, checkpointId: Internal.loadedFromDbCheckpointId})
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

  let hasIndex = (inMemTable: t) =>
    (filterKey: string) =>
      inMemTable.indexesByKey->Utils.Dict.dangerouslyGetNonOption(filterKey) !== None

  let getUnsafeOnIndex = (inMemTable: t) =>
    (filterKey: string) => {
      switch inMemTable.indexesByKey->Utils.Dict.dangerouslyGetNonOption(filterKey) {
      | None =>
        JsError.throwWithMessage(`Unexpected error. Must have an index for the filter ${filterKey}`)
      | Some({ids}) =>
        ids
        ->Utils.Set.toArray
        ->Array.filterMap(entityId =>
          switch inMemTable.latestEntityChangeById->Utils.Dict.dangerouslyGetNonOption(entityId) {
          | Some(change) => change->mapChangeToEntity
          | None => None
          }
        )
      }
    }

  let getOrCreateEqBucket = (inMemTable: t, ~table: Table.table, ~fieldName) =>
    switch inMemTable.eqBucketsByField->Utils.Dict.dangerouslyGetNonOption(fieldName) {
    | Some(bucket) => bucket
    | None =>
      let bucket = {
        keyOf: EntityFilter.makeValueKey(~table, ~fieldName),
        byValue: Utils.Map.make(),
        entityIdsByValue: Utils.Map.make(),
        valueByEntityId: Dict.make(),
        loadedValues: Utils.Set.make(),
      }
      inMemTable.latestEntityChangeById->Utils.Dict.forEachWithKey((change, entityId) =>
        switch change->mapChangeToEntity {
        | Some(entity) => bucket->addToEqBucket(~entityId, entity->EntityFilter.getField(fieldName))
        | None => ()
        }
      )
      inMemTable.eqBucketsByField->Dict.set(fieldName, bucket)
      inMemTable.hasIndexes = true
      bucket
    }

  // The values a filter constrains a single field to exactly, which is what a
  // bucket and the loaded set are keyed by. Everything else — ranges, several
  // fields, several operators — has no such list.
  let singleFieldValues = (filter: EntityFilter.t) =>
    switch filter->EntityFilter.asSingleOperator {
    | Some((fieldName, "_eq", fieldValue)) => Some((fieldName, [fieldValue]))
    | Some((fieldName, "_in", fieldValue)) => Some((fieldName, fieldValue->EntityFilter.asArray))
    | Some(_) | None => None
    }

  let addEmptyIndex = (inMemTable: t, ~filter: EntityFilter.t, ~table: Table.table) => {
    let filterKey = filter->EntityFilter.toString(~table)
    switch inMemTable.indexesByKey->Utils.Dict.dangerouslyGetNonOption(filterKey) {
    | Some(_) => () //Should not happen, this means the index already exists
    | None =>
      let index = {matcher: filter->EntityFilter.makeMatcher(~table), ids: Utils.Set.make()}
      inMemTable.indexesByKey->Dict.set(filterKey, index)
      inMemTable.hasIndexes = true

      switch filter->singleFieldValues {
      | Some((fieldName, fieldValues)) if EntityFilter.canUseEqualityBucket(~table, ~fieldName) =>
        let bucket = inMemTable->getOrCreateEqBucket(~table, ~fieldName)
        let visitedKeys = Utils.Set.make()
        fieldValues->Array.forEach(fieldValue => {
          let valueKey = bucket.keyOf(fieldValue)
          if !(visitedKeys->Utils.Set.has(valueKey)) {
            visitedKeys->Utils.Set.add(valueKey)->ignore
            switch bucket.byValue->Utils.Map.get(valueKey) {
            | Some(indexes) => indexes->Array.push(index)->ignore
            | None => bucket.byValue->Utils.Map.set(valueKey, [index])->ignore
            }
            switch bucket.entityIdsByValue->Utils.Map.get(valueKey) {
            | None => ()
            | Some(ids) =>
              ids->Utils.Set.forEach(entityId => {
                let change = inMemTable.latestEntityChangeById->Dict.getUnsafe(entityId)
                switch change->mapChangeToEntity {
                | Some(entity) =>
                  if index.matcher(entity) {
                    inMemTable->addToIndex(~index, ~entityId)
                  }
                | None => ()
                }
              })
            }
          }
        })
      | Some(_) | None =>
        inMemTable.scanIndexes->Array.push(index)->ignore
        inMemTable.latestEntityChangeById->Utils.Dict.forEach(change => {
          switch change->mapChangeToEntity {
          | Some(entity) =>
            if index.matcher(entity) {
              inMemTable->addToIndex(~index, ~entityId=inMemTable->getEntityKeyUnsafe(entity))
            }
          | None => ()
          }
        })
      }
    }
  }

  // Called once a query's rows are in the table, so every row the filter's
  // values could match is now in memory.
  let recordLoadedValues = (inMemTable: t, ~filter: EntityFilter.t, ~table: Table.table) =>
    switch filter->singleFieldValues {
    | Some((fieldName, fieldValues)) if EntityFilter.canUseEqualityBucket(~table, ~fieldName) =>
      let bucket = inMemTable->getOrCreateEqBucket(~table, ~fieldName)
      fieldValues->Array.forEach(fieldValue =>
        bucket.loadedValues->Utils.Set.add(bucket.keyOf(fieldValue))->ignore
      )
    | Some(_) | None => ()
    }

  let isFullyLoaded = (inMemTable: t, ~filter: EntityFilter.t) =>
    switch filter->singleFieldValues {
    | Some((fieldName, fieldValues)) =>
      switch inMemTable.eqBucketsByField->Utils.Dict.dangerouslyGetNonOption(fieldName) {
      | Some(bucket) =>
        fieldValues->Array.every(fieldValue =>
          bucket.loadedValues->Utils.Set.has(bucket.keyOf(fieldValue))
        )
      | None => false
      }
    | None => false
    }

  // Builds the index for a filter whose every value an earlier query already
  // loaded, so the call is served from the table instead of going to storage.
  let tryIndexFromLoadedValues = (inMemTable: t, ~filter: EntityFilter.t, ~table: Table.table) =>
    if inMemTable->isFullyLoaded(~filter) {
      inMemTable->addEmptyIndex(~filter, ~table)
    }
}
