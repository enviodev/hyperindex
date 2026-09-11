module Entity = {
  type relatedEntityId = string
  // The matcher is specialized from the filter once at index creation and
  // reused for every entity write against this index.
  type index = {
    matcher: EntityFilter.matcher,
    ids: Utils.Set.t<relatedEntityId>,
  }

  // Equality indexes on one field, found by the field's value rather than by
  // running their matchers, so a write costs a lookup per indexed field
  // instead of a pass over every registered index.
  type eqBucket = {
    keyOf: unknown => unknown,
    byValue: Utils.Map.t<unknown, index>,
  }

  type t = {
    latestEntityChangeById: dict<Change.t<Internal.entity>>,
    // Recorded changes (new latest ids + prevEntityChanges pushes), tracked
    // manually so InMemoryStore can gauge size without scanning every dict.
    mutable changesCount: float,
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
  }

  // Helper to extract an entity's id as a dict key. The raw id may be a
  // string/int/bigint, so it's stringified to a stable key for in-memory
  // indexing.
  exception UnexpectedIdNotDefinedOnEntity
  let getEntityIdUnsafe = (entity: Internal.entity): string =>
    switch (entity->(Utils.magic: Internal.entity => {"id": option<EntityId.t>}))["id"] {
    | Some(id) => id->EntityId.toKey
    | None =>
      UnexpectedIdNotDefinedOnEntity->ErrorHandling.mkLogAndRaise(
        ~msg="Property 'id' does not exist on expected entity object",
      )
    }

  let addToIndex = (self: t, ~index: index, ~entityId) => {
    index.ids->Utils.Set.add(entityId)->ignore
    switch self.indexesByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | Some(indexes) => indexes->Utils.Set.add(index)->ignore
    | None => self.indexesByEntityId->Dict.set(entityId, Utils.Set.fromArray([index]))
    }
  }

  let make = (): t => {
    latestEntityChangeById: Dict.make(),
    changesCount: 0.,
    prevEntityChanges: [],
    indexesByEntityId: Dict.make(),
    indexesByKey: Dict.make(),
    eqBucketsByField: Dict.make(),
    scanIndexes: [],
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
    self.latestEntityChangeById->Utils.Dict.forEach(change => {
      let checkpointId = change->Change.getCheckpointId
      if checkpointId > committedCheckpointId && !(checkpointId > upToCheckpointId) {
        changes->Array.push(change)
      }
    })
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
  }

  let updateIndexes = (self: t, ~entity: Internal.entity) => {
    let entityId = entity->getEntityIdUnsafe

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

      // A nullish column matches no equality index, and the key projections
      // would throw on it.
      if !(fieldValue->EntityFilter.nullish) {
        switch bucket.byValue->Utils.Map.get(bucket.keyOf(fieldValue)) {
        | Some(index) => self->addToIndex(~index, ~entityId)
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

  let deleteEntityFromIndexes = (self: t, ~entityId: string) =>
    switch self.indexesByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | None => ()
    | Some(indexes) =>
      indexes->Utils.Set.forEach(index => index.ids->Utils.Set.delete(entityId)->ignore)
      self.indexesByEntityId->Utils.Dict.deleteInPlace(entityId)
    }

  let set = (inMemTable: t, ~committedCheckpointId, change: Change.t<Internal.entity>) => {
    let entityKey = change->Change.getEntityId->EntityId.toKey
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
    | Set({entity}) => inMemTable->updateIndexes(~entity)
    | Delete({entityId}) => inMemTable->deleteEntityFromIndexes(~entityId=entityId->EntityId.toKey)
    }
    inMemTable.latestEntityChangeById->Dict.set(entityKey, change)
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
      let entityId = key->EntityId.unsafeOfString
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

  let addEmptyIndex = (inMemTable: t, ~filter: EntityFilter.t, ~table: Table.table) => {
    let filterKey = filter->EntityFilter.toString
    switch inMemTable.indexesByKey->Utils.Dict.dangerouslyGetNonOption(filterKey) {
    | Some(_) => () //Should not happen, this means the index already exists
    | None =>
      let index = {matcher: filter->EntityFilter.makeMatcher(~table), ids: Utils.Set.make()}
      inMemTable.indexesByKey->Dict.set(filterKey, index)

      switch filter {
      | Eq({fieldName, fieldValue}) =>
        let bucket = switch inMemTable.eqBucketsByField->Utils.Dict.dangerouslyGetNonOption(
          fieldName,
        ) {
        | Some(bucket) => bucket
        | None =>
          let bucket = {
            keyOf: EntityFilter.makeValueKey(~table, ~fieldName),
            byValue: Utils.Map.make(),
          }
          inMemTable.eqBucketsByField->Dict.set(fieldName, bucket)
          bucket
        }
        bucket.byValue->Utils.Map.set(bucket.keyOf(fieldValue), index)->ignore
      | Gt(_) | Lt(_) | In(_) | And(_) => inMemTable.scanIndexes->Array.push(index)->ignore
      }

      inMemTable.latestEntityChangeById->Utils.Dict.forEach(change => {
        switch change->mapChangeToEntity {
        | Some(entity) =>
          if index.matcher(entity) {
            inMemTable->addToIndex(~index, ~entityId=entity->getEntityIdUnsafe)
          }
        | None => ()
        }
      })
    }
  }
}
