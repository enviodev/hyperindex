@genType
type rawEventsKey = {
  chainId: int,
  eventId: string,
}

let hashRawEventsKey = (key: rawEventsKey) =>
  EventUtils.getEventIdKeyString(~chainId=key.chainId, ~eventId=key.eventId)

module EntityTables = {
  type t = dict<InMemoryTable.Entity.t<Internal.entity>>
  exception UndefinedEntity({entityName: string})
  let make = (entities: array<Internal.entityConfig>): t => {
    let init = Dict.make()
    entities->Array.forEach(entityConfig => {
      init->Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
    })
    init
  }

  let get = (type entity, self: t, ~entityName: string) => {
    switch self->Utils.Dict.dangerouslyGetNonOption(entityName) {
    | Some(table) =>
      table->(
        Utils.magic: InMemoryTable.Entity.t<Internal.entity> => InMemoryTable.Entity.t<entity>
      )

    | None =>
      UndefinedEntity({entityName: entityName})->ErrorHandling.mkLogAndRaise(
        ~msg="Unexpected, entity InMemoryTable is undefined",
      )
    }
  }

  let clone = (self: t) => {
    self
    ->Dict.toArray
    ->Array.map(((k, v)) => (k, v->InMemoryTable.Entity.clone))
    ->Dict.fromArray
  }
}

type effectCacheInMemTable = {
  idsToStore: array<string>,
  mutable invalidationsCount: int,
  dict: dict<Internal.effectOutput>,
  effect: Internal.effect,
}

type t = {
  rawEvents: InMemoryTable.t<rawEventsKey, InternalTable.RawEvents.t>,
  entities: dict<InMemoryTable.Entity.t<Internal.entity>>,
  effects: dict<effectCacheInMemTable>,
  mutable rollbackTargetCheckpointId: option<Internal.checkpointId>,
  mutable totalChangeCount: float,
}

let make = (~entities: array<Internal.entityConfig>, ~rollbackTargetCheckpointId=None): t => {
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  effects: Dict.make(),
  rollbackTargetCheckpointId,
  totalChangeCount: 0.,
}

let clone = (self: t) => {
  rawEvents: self.rawEvents->InMemoryTable.clone,
  entities: self.entities->EntityTables.clone,
  effects: Dict.mapValues(self.effects, table => {
    idsToStore: table.idsToStore->Array.copy,
    invalidationsCount: table.invalidationsCount,
    dict: table.dict->Utils.Dict.shallowCopy,
    effect: table.effect,
  }),
  rollbackTargetCheckpointId: self.rollbackTargetCheckpointId,
  totalChangeCount: self.totalChangeCount,
}

let getEffectInMemTable = (inMemoryStore: t, ~effect: Internal.effect) => {
  let key = effect.name
  switch inMemoryStore.effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table = {
      idsToStore: [],
      dict: Dict.make(),
      invalidationsCount: 0,
      effect,
    }
    inMemoryStore.effects->Dict.set(key, table)
    table
  }
}

let getInMemTable = (
  inMemoryStore: t,
  ~entityConfig: Internal.entityConfig,
): InMemoryTable.Entity.t<Internal.entity> => {
  inMemoryStore.entities->EntityTables.get(~entityName=entityConfig.name)
}

let entitySet = (
  inMemoryStore: t,
  ~entityConfig: Internal.entityConfig,
  ~change: Change.t<Internal.entity>,
  ~shouldSaveHistory,
  ~containsRollbackDiffChange=false,
) => {
  inMemoryStore
  ->getInMemTable(~entityConfig)
  ->InMemoryTable.Entity.set(change, ~shouldSaveHistory, ~containsRollbackDiffChange)
  inMemoryStore.totalChangeCount = inMemoryStore.totalChangeCount +. 1.
}

// After a background write completes, clean up entities that were written
// and evict stale loaded entities. Also clear rawEvents and effect caches.
let cleanupAfterWrite = (inMemoryStore: t, ~writtenCheckpointId: bigint) => {
  inMemoryStore.totalChangeCount = 0.
  inMemoryStore.entities
  ->Dict.valuesToArray
  ->Array.forEach(table => {
    table->InMemoryTable.Entity.cleanupAfterWrite(~writtenCheckpointId)
    inMemoryStore.totalChangeCount = inMemoryStore.totalChangeCount +. table.changeCount
  })

  // Clear raw events - they've been written
  inMemoryStore.rawEvents.dict
  ->Dict.keysToArray
  ->Array.forEach(key => {
    inMemoryStore.rawEvents.dict->Utils.Dict.deleteInPlace(key)
  })

  // Clear effect cache write tracking
  inMemoryStore.effects
  ->Dict.valuesToArray
  ->Array.forEach(table => {
    table.idsToStore->Array.splice(~start=0, ~remove=table.idsToStore->Array.length, ~insert=[])
    table.invalidationsCount = 0
  })

  // Reset rollback checkpoint after it's been written
  inMemoryStore.rollbackTargetCheckpointId = None
}

// Extract write data from in-memory store, queue background write,
// and manage in-memory capacity.
let prepareForNextBatch = async (
  inMemoryStore: t,
  ~batch: Batch.t,
  ~config: Config.t,
  ~isInReorgThreshold: bool,
  ~persistence: Persistence.t,
) => {
  let updatedEntities = persistence.allEntities->Array.filterMap(entityConfig => {
    let updates =
      inMemoryStore
      ->getInMemTable(~entityConfig)
      ->InMemoryTable.Entity.updates
    if updates->Utils.Array.isEmpty {
      None
    } else {
      Some({Persistence.entityConfig, updates})
    }
  })

  let effectCacheWriteData =
    inMemoryStore.effects
    ->Dict.valuesToArray
    ->Array.filterMap(({idsToStore, dict, effect, invalidationsCount}) => {
      switch idsToStore {
      | [] => None
      | ids =>
        let items = Belt.Array.makeUninitializedUnsafe(ids->Array.length)
        ids->Array.forEachWithIndex((id, index) => {
          items->Array.setUnsafe(
            index,
            ({id, output: dict->Dict.getUnsafe(id)}: Internal.effectCacheItem),
          )
        })
        Some({Persistence.effect, items, invalidationsCount})
      }
    })

  let writeArgs: Persistence.writeArgs = {
    batch,
    config,
    isInReorgThreshold,
    updatedEntities,
    rawEvents: inMemoryStore.rawEvents->InMemoryTable.values,
    effectCacheWriteData,
    rollbackTargetCheckpointId: inMemoryStore.rollbackTargetCheckpointId,
    onWriteComplete: writtenCheckpointId => {
      inMemoryStore->cleanupAfterWrite(~writtenCheckpointId)
    },
  }

  persistence->Persistence.startWrite(~writeArgs)

  let halfCapacity = (Env.targetInMemoryStoreSize :> float) /. 2.
  if inMemoryStore.totalChangeCount > halfCapacity {
    inMemoryStore->cleanupAfterWrite(~writtenCheckpointId=persistence.writtenCheckpointId)
    if inMemoryStore.totalChangeCount > halfCapacity {
      // Still over half - must wait for current write to finish, then prune again
      try {
        await persistence->Persistence.flushWrites
        inMemoryStore->cleanupAfterWrite(~writtenCheckpointId=persistence.writtenCheckpointId)
      } catch {
      // Write errors are already logged by Persistence.executeWrite
      | _ => ()
      }
    }
  }
}

// Apply rollback diff changes to the in-memory store.
// Only overwrites entities that actually changed — entities not in the diff
// remain cached and valid since they're unchanged by the rollback.
let applyRollbackDiff = (inMemoryStore: t, ~rollbackDiff: Persistence.rollbackDiff) => {
  inMemoryStore.rollbackTargetCheckpointId = Some(rollbackDiff.rollbackTargetCheckpointId)

  rollbackDiff.entityChanges->Array.forEach(({entityConfig, removedIds, restoredEntities}) => {
    removedIds->Array.forEach(entityId => {
      inMemoryStore->entitySet(
        ~entityConfig,
        ~change=Delete({
          entityId,
          checkpointId: rollbackDiff.rollbackDiffCheckpointId,
        }),
        ~shouldSaveHistory=false,
        ~containsRollbackDiffChange=true,
      )
    })

    restoredEntities->Array.forEach((entity: Internal.entity) => {
      inMemoryStore->entitySet(
        ~entityConfig,
        ~change=Set({
          entityId: entity.id,
          checkpointId: rollbackDiff.rollbackDiffCheckpointId,
          entity,
        }),
        ~shouldSaveHistory=false,
        ~containsRollbackDiffChange=true,
      )
    })
  })
}

let setBatchDcs = (inMemoryStore: t, ~batch: Batch.t, ~shouldSaveHistory) => {
  let entityConfig = InternalTable.EnvioAddresses.entityConfig

  let itemIdx = ref(0)

  for checkpoint in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpoint)
    let chainId = batch.checkpointChainIds->Array.getUnsafe(checkpoint)
    let checkpointEventsProcessed = batch.checkpointEventsProcessed->Array.getUnsafe(checkpoint)

    for idx in 0 to checkpointEventsProcessed - 1 {
      let item = batch.items->Array.getUnsafe(itemIdx.contents + idx)
      switch item->Internal.getItemDcs {
      | None => ()
      | Some(dcs) =>
        // Currently only events support contract registration, so we can cast to event item
        let eventItem = item->Internal.castUnsafeEventItem
        for dcIdx in 0 to dcs->Array.length - 1 {
          let dc = dcs->Array.getUnsafe(dcIdx)
          let entity: InternalTable.EnvioAddresses.t = {
            id: InternalTable.EnvioAddresses.makeId(~chainId, ~address=dc.address),
            chainId,
            contractName: dc.contractName,
            registrationBlock: eventItem.blockNumber,
            registrationLogIndex: eventItem.logIndex,
          }

          inMemoryStore->entitySet(
            ~entityConfig,
            ~change=Set({
              entityId: entity.id,
              checkpointId,
              entity: entity->InternalTable.EnvioAddresses.castToInternal,
            }),
            ~shouldSaveHistory,
          )
        }
      }
    }

    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}
