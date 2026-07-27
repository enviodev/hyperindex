module Entity = {
  type relatedEntityId = string
  type filterWithRelatedIds = (EntityFilter.t, Utils.Set.t<relatedEntityId>)
  // Keyed by EntityFilter.toString
  type filterIndices = dict<filterWithRelatedIds>

  type entityFilters = Utils.Set.t<EntityFilter.t>
  type t = {
    latestEntityChangeById: dict<Change.t<Internal.entity>>,
    // Recorded changes (new latest ids + prevEntityChanges pushes), tracked
    // manually so InMemoryStore can gauge size without scanning every dict.
    mutable changesCount: float,
    // Swapped out when a write starts so processing keeps appending while the
    // previous changes persist in the background.
    mutable prevEntityChanges: array<Change.t<Internal.entity>>,
    mutable filtersByEntityId: dict<entityFilters>,
    mutable filterIndices: filterIndices,
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

  let getOrCreateEntityFilters = (self: t, ~entityId) =>
    switch self.filtersByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | Some(s) => s
    | None =>
      let s = Utils.Set.make()
      self.filtersByEntityId->Dict.set(entityId, s)
      s
    }

  let make = (): t => {
    latestEntityChangeById: Dict.make(),
    changesCount: 0.,
    prevEntityChanges: [],
    filtersByEntityId: Dict.make(),
    filterIndices: Dict.make(),
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
  // (re-readable from the db) and clears the per-batch indices (rebuilt on the next
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
    self.filtersByEntityId = Dict.make()
    self.filterIndices = Dict.make()
  }

  let updateIndices = (self: t, ~entity: Internal.entity) => {
    let entityId = entity->getEntityIdUnsafe
    let entityAsDict = entity->(Utils.magic: Internal.entity => dict<EntityFilter.FieldValue.t>)

    //Remove any invalid filters on entity
    switch self.filtersByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | None => ()
    | Some(entityFilters) =>
      entityFilters->Utils.Set.forEach(filter => {
        if !(filter->EntityFilter.matches(~entity=entityAsDict)) {
          entityFilters->Utils.Set.delete(filter)->ignore
        }
      })
    }

    self.filterIndices->Utils.Dict.forEach(((filter, relatedEntityIds)) => {
      if filter->EntityFilter.matches(~entity=entityAsDict) {
        //Add entity id to the filter index and the filter to entity filters
        relatedEntityIds->Utils.Set.add(entityId)->ignore
        self->getOrCreateEntityFilters(~entityId)->Utils.Set.add(filter)->ignore
      } else {
        relatedEntityIds->Utils.Set.delete(entityId)->ignore
      }
    })
  }

  let deleteEntityFromIndices = (self: t, ~entityId: string) =>
    switch self.filtersByEntityId->Utils.Dict.dangerouslyGetNonOption(entityId) {
    | None => ()
    | Some(entityFilters) =>
      entityFilters->Utils.Set.forEach(filter => {
        switch self.filterIndices->Utils.Dict.dangerouslyGetNonOption(
          filter->EntityFilter.toString,
        ) {
        | Some((_filter, relatedEntityIds)) =>
          let _wasRemoved = relatedEntityIds->Utils.Set.delete(entityId)
        | None => () //Unexpected filter index should exist if it is in entityFilters
        }
        let _wasRemoved = entityFilters->Utils.Set.delete(filter)
      })
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
    | Set({entity}) => inMemTable->updateIndices(~entity)
    | Delete({entityId}) => inMemTable->deleteEntityFromIndices(~entityId=entityId->EntityId.toKey)
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
      inMemTable.filterIndices->Utils.Dict.dangerouslyGetNonOption(filterKey) !== None

  let getUnsafeOnIndex = (inMemTable: t) => {
    let getEntity = inMemTable->getUnsafe
    (filterKey: string) => {
      switch inMemTable.filterIndices->Utils.Dict.dangerouslyGetNonOption(filterKey) {
      | None =>
        JsError.throwWithMessage(`Unexpected error. Must have an index for the filter ${filterKey}`)
      | Some((_filter, relatedEntityIds)) =>
        relatedEntityIds
        ->Utils.Set.toArray
        ->Array.filterMap(entityId => {
          switch inMemTable.latestEntityChangeById->Dict.has(entityId) {
          | true => getEntity(entityId)
          | false => None
          }
        })
      }
    }
  }

  let addEmptyIndex = (inMemTable: t, ~filter: EntityFilter.t) => {
    let filterKey = filter->EntityFilter.toString
    switch inMemTable.filterIndices->Utils.Dict.dangerouslyGetNonOption(filterKey) {
    | Some(_) => () //Should not happen, this means the index already exists
    | None =>
      let relatedEntityIds = Utils.Set.make()
      inMemTable.latestEntityChangeById->Utils.Dict.forEach(change => {
        switch change->mapChangeToEntity {
        | Some(entity) =>
          let entityAsDict =
            entity->(Utils.magic: Internal.entity => dict<EntityFilter.FieldValue.t>)
          if filter->EntityFilter.matches(~entity=entityAsDict) {
            let entityId = entity->getEntityIdUnsafe
            let _ = inMemTable->getOrCreateEntityFilters(~entityId)->Utils.Set.add(filter)
            let _ = relatedEntityIds->Utils.Set.add(entityId)
          }
        | None => ()
        }
      })
      inMemTable.filterIndices->Dict.set(filterKey, (filter, relatedEntityIds))
    }
  }
}
