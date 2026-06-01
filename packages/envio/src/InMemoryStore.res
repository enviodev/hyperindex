module EntityTables = {
  type t = dict<InMemoryTable.Entity.t>
  exception UndefinedEntity({entityName: string})
  let make = (entities: array<Internal.entityConfig>): t => {
    let init = Dict.make()
    entities->Array.forEach(entityConfig => {
      init->Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
    })
    init
  }

  let get = (self: t, ~entityName: string) => {
    switch self->Utils.Dict.dangerouslyGetNonOption(entityName) {
    | Some(table) => table
    | None =>
      UndefinedEntity({entityName: entityName})->ErrorHandling.mkLogAndRaise(
        ~msg="Unexpected, entity InMemoryTable is undefined",
      )
    }
  }
}

type effectCacheInMemTable = {
  idsToStore: array<string>,
  mutable invalidationsCount: int,
  dict: dict<Internal.effectOutput>,
  effect: Internal.effect,
}

// A batch write that has been fired off but not yet awaited. We keep the
// in-flight effects snapshot so the next batch can serve effect cache hits
// from it instead of recomputing or reading the not-yet-committed DB rows.
type pendingPersistence = {
  promise: promise<unit>,
  effects: dict<effectCacheInMemTable>,
}

type t = {
  allEntities: array<Internal.entityConfig>,
  mutable rawEvents: array<InternalTable.RawEvents.t>,
  mutable entities: dict<InMemoryTable.Entity.t>,
  mutable effects: dict<effectCacheInMemTable>,
  mutable rollback: option<Persistence.rollback>,
  mutable committedCheckpointId: Internal.checkpointId,
  mutable pendingPersistence: option<pendingPersistence>,
}

let make = (
  ~entities: array<Internal.entityConfig>,
  ~committedCheckpointId=Internal.initialCheckpointId,
): t => {
  allEntities: entities,
  rawEvents: [],
  entities: EntityTables.make(entities),
  effects: Dict.make(),
  rollback: None,
  committedCheckpointId,
  pendingPersistence: None,
}

// Once the store holds this many entities across all tables, we drop them
// after a batch write so it doesn't grow unbounded on long running indexers.
let keepLatestChangesLimit = 50_000.

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
): InMemoryTable.Entity.t => {
  inMemoryStore.entities->EntityTables.get(~entityName=entityConfig.name)
}

let isRollingBack = (inMemoryStore: t) => inMemoryStore.rollback !== None

// Awaits an in-flight batch write so the DB reflects everything up to the last
// fired batch. Must run before any read of committed state (rollback, exit).
let flushPendingPersistence = async (inMemoryStore: t) =>
  switch inMemoryStore.pendingPersistence {
  | Some({promise}) =>
    inMemoryStore.pendingPersistence = None
    await promise
  | None => ()
  }

// Synchronously snapshots the batch for writing and resets the store so the next
// batch can start processing immediately. Returns the not-yet-awaited storage
// write together with whether the entity tables kept their latest changes (and
// thus may be persisted concurrently) and the effects snapshot handed to the
// write (kept for read-through while the write is in flight).
let prepareWriteBatch = (
  inMemoryStore: t,
  ~persistence: Persistence.t,
  ~batch: Batch.t,
  ~config,
  ~isInReorgThreshold,
) =>
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    JsError.throwWithMessage(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) =>
    let committedCheckpointId = inMemoryStore.committedCheckpointId
    // Decide before the keepMap below trims prevEntityChanges from changesCount,
    // so the signal still reflects every change currently held in memory.
    let keepLatestChanges = {
      let totalChanges = ref(0.)
      persistence.allEntities->Array.forEach(entityConfig => {
        totalChanges :=
          totalChanges.contents +. (inMemoryStore->getInMemTable(~entityConfig)).changesCount
      })
      totalChanges.contents < keepLatestChangesLimit
    }
    let updatedEntities = persistence.allEntities->Array.filterMap(entityConfig => {
      let table = inMemoryStore->getInMemTable(~entityConfig)

      // The reset below drops prevEntityChanges and we reuse the array as the
      // write buffer here, so drop it from the count before appending to it.
      table.changesCount = table.changesCount -. table.prevEntityChanges->Array.length->Int.toFloat
      let changes = table.prevEntityChanges
      table.latestEntityChangeById->Utils.Dict.forEach(change =>
        if change->Change.getCheckpointId > committedCheckpointId {
          changes->Array.push(change)
        }
      )
      if changes->Utils.Array.isEmpty {
        None
      } else {
        Some(({entityConfig, changes}: Persistence.updatedEntity))
      }
    })
    let effectsSnapshot = inMemoryStore.effects
    let updatedEffectsCache = {
      let acc = []
      effectsSnapshot->Utils.Dict.forEach(inMemTable => {
        let {idsToStore, dict, effect, invalidationsCount} = inMemTable
        switch idsToStore {
        | [] => ()
        | ids =>
          let items = ids->Array.map((id): Internal.effectCacheItem => {
            id,
            output: dict->Dict.getUnsafe(id),
          })
          let effectName = effect.name
          let effectCacheRecord = switch cache->Utils.Dict.dangerouslyGetNonOption(effectName) {
          | Some(c) => c
          | None =>
            let c: Persistence.effectCacheRecord = {effectName, count: 0}
            cache->Dict.set(effectName, c)
            c
          }
          let shouldInitialize = effectCacheRecord.count === 0
          effectCacheRecord.count =
            effectCacheRecord.count + items->Array.length - invalidationsCount
          Prometheus.EffectCacheCount.set(~count=effectCacheRecord.count, ~effectName)
          acc
          ->Array.push(({effect, items, shouldInitialize}: Persistence.updatedEffectCache))
          ->ignore
        }
      })
      acc
    }

    let rawEvents = inMemoryStore.rawEvents
    let rollback = inMemoryStore.rollback

    inMemoryStore.rawEvents = []
    inMemoryStore.effects = Dict.make()
    inMemoryStore.rollback = None
    inMemoryStore.committedCheckpointId = switch batch.checkpointIds->Utils.Array.last {
    | Some(checkpointId) => checkpointId
    | None => committedCheckpointId
    }
    persistence.allEntities->Array.forEach(entityConfig => {
      let table = inMemoryStore->getInMemTable(~entityConfig)
      let resetTable = keepLatestChanges
        ? table->InMemoryTable.Entity.resetButKeepLatestChanges
        : InMemoryTable.Entity.make()
      inMemoryStore.entities->Dict.set((entityConfig.name :> string), resetTable)
    })

    let write = () =>
      persistence.storage.writeBatch(
        ~batch,
        ~rawEvents,
        ~rollback,
        ~isInReorgThreshold,
        ~config,
        ~allEntities=persistence.allEntities,
        ~updatedEntities,
        ~updatedEffectsCache,
      )

    (write, keepLatestChanges, effectsSnapshot)
  }

let writeBatch = async (
  inMemoryStore: t,
  ~persistence: Persistence.t,
  ~batch,
  ~config,
  ~isInReorgThreshold,
) => {
  // Await the previous batch's write before snapshotting the new one, so at most
  // one write is ever in flight and writes land in batch order.
  await inMemoryStore->flushPendingPersistence

  let (write, keepLatestChanges, effects) =
    inMemoryStore->prepareWriteBatch(~persistence, ~batch, ~config, ~isInReorgThreshold)

  if keepLatestChanges {
    // Entities stay in memory, so the next batch reads them without hitting the
    // not-yet-committed DB. Fire the write and return control.
    let promise = write()
    // Mark the promise handled so an early rejection doesn't crash the process
    // before flushPendingPersistence awaits it.
    let _ = promise->Utils.Promise.silentCatch
    inMemoryStore.pendingPersistence = Some({promise, effects})
  } else {
    // The store dropped its latest changes, so the next batch may read these
    // entities from the DB. Await the write to keep the DB consistent first.
    await write()
  }
}

let prepareRollbackDiff = async (
  inMemoryStore: t,
  ~persistence: Persistence.t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
) => {
  // The rollback reads committed state from the DB, so the in-flight write must
  // land before we clear the in-memory store.
  await inMemoryStore->flushPendingPersistence

  inMemoryStore.rawEvents = []
  inMemoryStore.entities = EntityTables.make(inMemoryStore.allEntities)
  inMemoryStore.effects = Dict.make()
  inMemoryStore.rollback = Some({
    targetCheckpointId: rollbackTargetCheckpointId,
    diffCheckpointId: rollbackDiffCheckpointId,
  })

  let deletedEntities = Dict.make()
  let setEntities = Dict.make()

  let _ = await persistence.allEntities
  ->Array.map(async entityConfig => {
    let entityTable = inMemoryStore->getInMemTable(~entityConfig)

    let (removedIdsResult, restoredEntitiesResult) = await persistence.storage.getRollbackData(
      ~entityConfig,
      ~rollbackTargetCheckpointId,
    )

    removedIdsResult->Array.forEach(data => {
      deletedEntities->Utils.Dict.push(entityConfig.name, data["id"])
      entityTable->InMemoryTable.Entity.set(
        ~committedCheckpointId=inMemoryStore.committedCheckpointId,
        Delete({
          entityId: data["id"],
          checkpointId: rollbackDiffCheckpointId,
        }),
      )
    })

    let restoredEntities = restoredEntitiesResult->S.parseOrThrow(entityConfig.rowsSchema)

    restoredEntities->Array.forEach((entity: Internal.entity) => {
      setEntities->Utils.Dict.push(entityConfig.name, entity.id)
      entityTable->InMemoryTable.Entity.set(
        ~committedCheckpointId=inMemoryStore.committedCheckpointId,
        Set({
          entityId: entity.id,
          checkpointId: rollbackDiffCheckpointId,
          entity,
        }),
      )
    })
  })
  ->Promise.all

  {
    "deletedEntities": deletedEntities,
    "setEntities": setEntities,
  }
}

let setBatchDcs = (inMemoryStore: t, ~batch: Batch.t) => {
  let inMemTable =
    inMemoryStore->getInMemTable(~entityConfig=InternalTable.EnvioAddresses.entityConfig)

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

          inMemTable->InMemoryTable.Entity.set(
            ~committedCheckpointId=inMemoryStore.committedCheckpointId,
            Set({
              entityId: entity.id,
              checkpointId,
              entity: entity->InternalTable.EnvioAddresses.castToInternal,
            }),
          )
        }
      }
    }

    itemIdx := itemIdx.contents + checkpointEventsProcessed
  }
}
