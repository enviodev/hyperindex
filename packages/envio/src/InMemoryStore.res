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
    let init = Js.Dict.empty()
    entities->Belt.Array.forEach(entityConfig => {
      init->Js.Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
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
    ->Js.Dict.entries
    ->Belt.Array.map(((k, v)) => (k, v->InMemoryTable.Entity.clone))
    ->Js.Dict.fromArray
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

let make = (~entities: array<Internal.entityConfig>): t => {
  rawEvents: InMemoryTable.make(~hash=hashRawEventsKey),
  entities: EntityTables.make(entities),
  effects: Js.Dict.empty(),
  rollbackTargetCheckpointId: None,
  totalChangeCount: 0.,
}

let clone = (self: t) => {
  rawEvents: self.rawEvents->InMemoryTable.clone,
  entities: self.entities->EntityTables.clone,
  effects: Js.Dict.map(table => {
    idsToStore: table.idsToStore->Array.copy,
    invalidationsCount: table.invalidationsCount,
    dict: table.dict->Utils.Dict.shallowCopy,
    effect: table.effect,
  }, self.effects),
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
      dict: Js.Dict.empty(),
      invalidationsCount: 0,
      effect,
    }
    inMemoryStore.effects->Js.Dict.set(key, table)
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
  ->Js.Dict.values
  ->Belt.Array.forEach(table => {
    table->InMemoryTable.Entity.cleanupAfterWrite(~writtenCheckpointId)
    inMemoryStore.totalChangeCount = inMemoryStore.totalChangeCount +. table.changeCount
  })

  // Clear raw events - they've been written
  inMemoryStore.rawEvents.dict
  ->Js.Dict.keys
  ->Belt.Array.forEach(key => {
    inMemoryStore.rawEvents.dict->Utils.Dict.deleteInPlace(key)
  })

  // Clear effect cache write tracking
  inMemoryStore.effects
  ->Js.Dict.values
  ->Belt.Array.forEach(table => {
    Js.Array2.removeCountInPlace(table.idsToStore, ~pos=0, ~count=table.idsToStore->Array.length)->ignore
    table.invalidationsCount = 0
  })
}

// Manage in-memory capacity after queueing a background write.
// If more than half capacity is used, prune written entities.
// If still over half after prune, flush writes and prune again.
let prepareForNextBatch = async (
  inMemoryStore: t,
  ~writtenCheckpointId: bigint,
  ~flushWrites: unit => promise<result<bigint, ErrorHandling.t>>,
) => {
  let halfCapacity = (Env.targetInMemoryStoreSize :> float) /. 2.
  if inMemoryStore.totalChangeCount > halfCapacity {
    inMemoryStore->cleanupAfterWrite(~writtenCheckpointId)
    if inMemoryStore.totalChangeCount > halfCapacity {
      switch await flushWrites() {
      | Error(errHandler) => errHandler->ErrorHandling.log
      | Ok(writtenCheckpointId) =>
        inMemoryStore->cleanupAfterWrite(~writtenCheckpointId)
      }
    }
  }
}

// Apply rollback diff changes to the in-memory store.
// Only overwrites entities that actually changed — entities not in the diff
// remain cached and valid since they're unchanged by the rollback.
let applyRollbackDiff = (inMemoryStore: t, ~rollbackDiff: Persistence.rollbackDiff) => {
  inMemoryStore.rollbackTargetCheckpointId = Some(rollbackDiff.rollbackTargetCheckpointId)

  rollbackDiff.entityChanges->Belt.Array.forEach(({entityConfig, removedIds, restoredEntities}) => {
    removedIds->Js.Array2.forEach(entityId => {
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

    restoredEntities->Belt.Array.forEach((entity: Internal.entity) => {
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
  let entityConfig = InternalTable.DynamicContractRegistry.entityConfig

  let itemIdx = ref(0)

  for checkpoint in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Js.Array2.unsafe_get(checkpoint)
    let chainId = batch.checkpointChainIds->Js.Array2.unsafe_get(checkpoint)
    let checkpointEventsProcessed =
      batch.checkpointEventsProcessed->Js.Array2.unsafe_get(checkpoint)

    for idx in 0 to checkpointEventsProcessed - 1 {
      let item = batch.items->Js.Array2.unsafe_get(itemIdx.contents + idx)
      switch item->Internal.getItemDcs {
      | None => ()
      | Some(dcs) =>
        // Currently only events support contract registration, so we can cast to event item
        let eventItem = item->Internal.castUnsafeEventItem
        for dcIdx in 0 to dcs->Array.length - 1 {
          let dc = dcs->Js.Array2.unsafe_get(dcIdx)
          let entity: InternalTable.DynamicContractRegistry.t = {
            id: InternalTable.DynamicContractRegistry.makeId(~chainId, ~contractAddress=dc.address),
            chainId,
            contractAddress: dc.address,
            contractName: dc.contractName,
            registeringEventBlockNumber: eventItem.blockNumber,
            registeringEventLogIndex: eventItem.logIndex,
            registeringEventBlockTimestamp: eventItem.timestamp,
            registeringEventContractName: eventItem.eventConfig.contractName,
            registeringEventName: eventItem.eventConfig.name,
            registeringEventSrcAddress: eventItem.event.srcAddress,
          }

          inMemoryStore->entitySet(
            ~entityConfig,
            ~change=Set({
              entityId: entity.id,
              checkpointId,
              entity: entity->InternalTable.DynamicContractRegistry.castToInternal,
            }),
            ~shouldSaveHistory,
          )
        }
      }
    }

    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}
