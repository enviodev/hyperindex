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
  mutable idsToStore: array<string>,
  mutable invalidationsCount: int,
  // Live cache reads; swapped into pendingDict while a write is in flight.
  mutable dict: dict<Internal.effectOutput>,
  // In-flight write's outputs, kept readable until it completes.
  mutable pendingDict: dict<Internal.effectOutput>,
  effect: Internal.effect,
}

type t = {
  allEntities: array<Internal.entityConfig>,
  mutable rawEvents: array<InternalTable.RawEvents.t>,
  mutable entities: dict<InMemoryTable.Entity.t>,
  mutable effects: dict<effectCacheInMemTable>,
  mutable rollback: option<Persistence.rollback>,
  // Last checkpoint persisted to the db.
  mutable committedCheckpointId: Internal.checkpointId,
  // Processing frontier; runs ahead of committedCheckpointId during background writes.
  mutable processedCheckpointId: Internal.checkpointId,
  // Processed but not yet written; drained in runs split at isInReorgThreshold changes.
  mutable processedBatches: array<Batch.t>,
  // The single in-flight write loop; None when idle.
  mutable writeFiber: option<promise<unit>>,
  // A failed background write, surfaced at the next boundary/flush.
  mutable persistenceError: option<exn>,
  // Woken after every commit for capacity/flush waiters.
  mutable commitWaiters: array<unit => unit>,
  // Static for the store's lifetime.
  persistence: Persistence.t,
  config: Config.t,
  // Latest metadata staged per chain; used to skip unchanged restages.
  mutable chainMeta: dict<InternalTable.Chains.metaFields>,
  // Set on a real change. Folded into a batch write, else flushed on the throttle.
  mutable chainMetaDirty: bool,
  // Throttles metadata-only writes when no batches flow.
  chainMetaThrottler: Throttler.t,
}

let make = (
  ~entities: array<Internal.entityConfig>,
  ~committedCheckpointId=Internal.initialCheckpointId,
  ~persistence: Persistence.t,
  ~config: Config.t,
): t => {
  let chainMetaThrottler = {
    let intervalMillis = Env.ThrottleWrites.chainMetadataIntervalMillis
    Throttler.make(
      ~intervalMillis,
      ~logger=Logging.createChild(
        ~params={
          "context": "Throttler for chain metadata writes",
          "intervalMillis": intervalMillis,
        },
      ),
    )
  }

  {
    allEntities: entities,
    rawEvents: [],
    entities: EntityTables.make(entities),
    effects: Dict.make(),
    rollback: None,
    committedCheckpointId,
    processedCheckpointId: committedCheckpointId,
    processedBatches: [],
    writeFiber: None,
    persistenceError: None,
    commitWaiters: [],
    persistence,
    config,
    chainMeta: Dict.make(),
    chainMetaDirty: false,
    chainMetaThrottler,
  }
}

// Max uncommitted changes before processing waits for the cycle to free capacity.
let keepLatestChangesLimit = 50_000.

let getEffectInMemTable = (inMemoryStore: t, ~effect: Internal.effect) => {
  let key = effect.name
  switch inMemoryStore.effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table = {
      idsToStore: [],
      dict: Dict.make(),
      pendingDict: Dict.make(),
      invalidationsCount: 0,
      effect,
    }
    inMemoryStore.effects->Dict.set(key, table)
    table
  }
}

// Effect cache read, also consulting the in-flight write's pending values.
let getEffectOutput = (inMemTable: effectCacheInMemTable, key) =>
  switch inMemTable.dict->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(_) as found => found
  | None => inMemTable.pendingDict->Utils.Dict.dangerouslyGetNonOption(key)
  }

let getInMemTable = (
  inMemoryStore: t,
  ~entityConfig: Internal.entityConfig,
): InMemoryTable.Entity.t => {
  inMemoryStore.entities->EntityTables.get(~entityName=entityConfig.name)
}

let isRollingBack = (inMemoryStore: t) => inMemoryStore.rollback !== None

let getChangesCount = (inMemoryStore: t) => {
  let total = ref(0.)
  inMemoryStore.allEntities->Array.forEach(entityConfig => {
    total := total.contents +. (inMemoryStore->getInMemTable(~entityConfig)).changesCount
  })
  total.contents
}

let wakeCommitWaiters = (inMemoryStore: t) => {
  let waiters = inMemoryStore.commitWaiters
  inMemoryStore.commitWaiters = []
  waiters->Array.forEach(resolve => resolve())
}

let waitForCommit = (inMemoryStore: t): promise<unit> =>
  Promise.make((resolve, _) => {
    inMemoryStore.commitWaiters->Array.push(resolve)->ignore
  })

// Drains the leading run of batches sharing isInReorgThreshold into one write, so
// a write never mixes history-saving modes. Only called when non-empty.
let drainBatchRun = (inMemoryStore: t): Batch.t => {
  let all = inMemoryStore.processedBatches
  let isInReorgThreshold = (all->Array.getUnsafe(0)).isInReorgThreshold

  let rest = []
  let progressedChainsById = Dict.make()
  let totalBatchSize = ref(0)
  let checkpointIds = []
  let checkpointChainIds = []
  let checkpointBlockNumbers = []
  let checkpointBlockHashes = []
  let checkpointEventsProcessed = []
  all->Array.forEach(batch => {
    // Past the boundary, every later batch follows, preserving order.
    if rest->Utils.Array.isEmpty && batch.isInReorgThreshold == isInReorgThreshold {
      batch.progressedChainsById->Utils.Dict.forEachWithKey((chainAfterBatch, key) =>
        progressedChainsById->Dict.set(key, chainAfterBatch)
      )
      totalBatchSize := totalBatchSize.contents + batch.totalBatchSize
      checkpointIds->Array.pushMany(batch.checkpointIds)
      checkpointChainIds->Array.pushMany(batch.checkpointChainIds)
      checkpointBlockNumbers->Array.pushMany(batch.checkpointBlockNumbers)
      checkpointBlockHashes->Array.pushMany(batch.checkpointBlockHashes)
      checkpointEventsProcessed->Array.pushMany(batch.checkpointEventsProcessed)
    } else {
      rest->Array.push(batch)
    }
  })
  inMemoryStore.processedBatches = rest

  {
    totalBatchSize: totalBatchSize.contents,
    items: [],
    progressedChainsById,
    isInReorgThreshold,
    checkpointIds,
    checkpointChainIds,
    checkpointBlockNumbers,
    checkpointBlockHashes,
    checkpointEventsProcessed,
  }
}

// Snapshots effects to persist, moving the live dict into pendingDict so reads
// stay warm during the write, then starts a fresh live dict.
let snapshotEffects = (inMemoryStore: t, ~cache): array<Persistence.updatedEffectCache> => {
  let acc = []
  inMemoryStore.effects->Utils.Dict.forEach(inMemTable => {
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
      effectCacheRecord.count = effectCacheRecord.count + items->Array.length - invalidationsCount
      Prometheus.EffectCacheCount.set(~count=effectCacheRecord.count, ~effectName)
      acc->Array.push(({effect, items, shouldInitialize}: Persistence.updatedEffectCache))->ignore
    }
    inMemTable.pendingDict = dict
    inMemTable.dict = Dict.make()
    inMemTable.idsToStore = []
    inMemTable.invalidationsCount = 0
  })
  acc
}

let runOneWrite = async (inMemoryStore: t, ~persistence: Persistence.t, ~config) => {
  let cache = switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    JsError.throwWithMessage(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) => cache
  }

  // Copy before the await: the batch write reads this later, in-transaction. A
  // restage during the write re-dirties the flag and is rewritten next iteration.
  let chainMetaData = if inMemoryStore.chainMetaDirty {
    inMemoryStore.chainMetaDirty = false
    Some(inMemoryStore.chainMeta->Utils.Dict.shallowCopy)
  } else {
    None
  }

  switch inMemoryStore.processedBatches {
  | [] =>
    // Metadata only: a cheap upsert, still serialized by the single write loop.
    switch chainMetaData {
    | Some(chainsData) =>
      await persistence.storage.setChainMeta(chainsData)->Utils.Promise.ignoreValue
    | None => ()
    }
  | _ =>
    let committedCheckpointId = inMemoryStore.committedCheckpointId
    let batch = inMemoryStore->drainBatchRun
    // Entity changes above this checkpoint belong to later batches, written next.
    let upToCheckpointId = switch batch.checkpointIds->Utils.Array.last {
    | Some(checkpointId) => checkpointId
    | None => committedCheckpointId
    }

    // Not gated by isInReorgThreshold, so flushed in full rather than split.
    let rawEvents = inMemoryStore.rawEvents
    inMemoryStore.rawEvents = []
    let rollback = inMemoryStore.rollback
    inMemoryStore.rollback = None

    let updatedEntities = persistence.allEntities->Array.filterMap(entityConfig => {
      let table = inMemoryStore->getInMemTable(~entityConfig)
      let changes =
        table->InMemoryTable.Entity.snapshotChanges(~committedCheckpointId, ~upToCheckpointId)
      if changes->Utils.Array.isEmpty {
        None
      } else {
        Some(({entityConfig, changes}: Persistence.updatedEntity))
      }
    })
    let updatedEffectsCache = snapshotEffects(inMemoryStore, ~cache)

    await persistence.storage.writeBatch(
      ~batch,
      ~rawEvents,
      ~rollback,
      ~isInReorgThreshold=batch.isInReorgThreshold,
      ~config,
      ~allEntities=persistence.allEntities,
      ~updatedEntities,
      ~updatedEffectsCache,
      ~chainMetaData,
    )

    inMemoryStore.committedCheckpointId = upToCheckpointId
    inMemoryStore.effects->Utils.Dict.forEach(inMemTable => inMemTable.pendingDict = Dict.make())
  }
}

let hasPendingWrite = (inMemoryStore: t) =>
  inMemoryStore.processedBatches->Utils.Array.notEmpty || inMemoryStore.chainMetaDirty

let runWriteLoop = async (inMemoryStore: t) => {
  while inMemoryStore->hasPendingWrite && inMemoryStore.persistenceError->Option.isNone {
    try {
      await runOneWrite(
        inMemoryStore,
        ~persistence=inMemoryStore.persistence,
        ~config=inMemoryStore.config,
      )
      inMemoryStore->wakeCommitWaiters
    } catch {
    | exn => inMemoryStore.persistenceError = Some(exn)
    }
  }
  inMemoryStore.writeFiber = None
  inMemoryStore->wakeCommitWaiters
}

let kick = (inMemoryStore: t) =>
  if (
    inMemoryStore.writeFiber->Option.isNone &&
    inMemoryStore.persistenceError->Option.isNone &&
    inMemoryStore->hasPendingWrite
  ) {
    inMemoryStore.writeFiber = Some(runWriteLoop(inMemoryStore))
  }

let metaFieldsEqual = (a: InternalTable.Chains.metaFields, b: InternalTable.Chains.metaFields) =>
  a.firstEventBlockNumber == b.firstEventBlockNumber &&
  a.latestFetchedBlockNumber == b.latestFetchedBlockNumber &&
  a.isHyperSync == b.isHyperSync &&
  // Date is boxed; compare epoch ms.
  a.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime) ==
    b.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime)

// Stages chain metadata, dirtying only on a real change so restages are no-ops.
let setChainMeta = (inMemoryStore: t, chainsData: dict<InternalTable.Chains.metaFields>) => {
  chainsData->Utils.Dict.forEachWithKey((meta, chainId) => {
    let changed = switch inMemoryStore.chainMeta->Utils.Dict.dangerouslyGetNonOption(chainId) {
    | Some(prev) => !metaFieldsEqual(meta, prev)
    | None => true
    }
    if changed {
      inMemoryStore.chainMeta->Dict.set(chainId, meta)
      inMemoryStore.chainMetaDirty = true
    }
  })
  if inMemoryStore.chainMetaDirty {
    inMemoryStore.chainMetaThrottler->Throttler.schedule(() => {
      inMemoryStore->kick
      Promise.resolve()
    })
  }
}

// Records a processed batch and kicks the cycle; the db write is off the processing path.
let commitBatch = (inMemoryStore: t, ~batch: Batch.t) => {
  inMemoryStore.processedBatches->Array.push(batch)->ignore
  switch batch.checkpointIds->Utils.Array.last {
  | Some(checkpointId) => inMemoryStore.processedCheckpointId = checkpointId
  | None => ()
  }
  inMemoryStore->kick
}

// Blocks until under keepLatestChangesLimit changes, dropping committed ones first.
let rec awaitCapacity = async (inMemoryStore: t) => {
  switch inMemoryStore.persistenceError {
  | Some(exn) => throw(exn)
  | None => ()
  }
  if inMemoryStore->getChangesCount >= keepLatestChangesLimit {
    inMemoryStore.allEntities->Array.forEach(entityConfig =>
      inMemoryStore
      ->getInMemTable(~entityConfig)
      ->InMemoryTable.Entity.dropCommittedChanges(
        ~committedCheckpointId=inMemoryStore.committedCheckpointId,
      )
    )

    // Only wait if a queued batch can free capacity; else waiting would deadlock
    // (e.g. a large rollback diff staged without a batch), so let processing proceed.
    if (
      inMemoryStore->getChangesCount >= keepLatestChangesLimit &&
        inMemoryStore.processedBatches->Utils.Array.notEmpty
    ) {
      inMemoryStore->kick
      await inMemoryStore->waitForCommit
      await inMemoryStore->awaitCapacity
    }
  }
}

// Awaits until all processed batches are persisted.
let rec flush = async (inMemoryStore: t) => {
  switch inMemoryStore.persistenceError {
  | Some(exn) => throw(exn)
  | None => ()
  }
  inMemoryStore->kick
  switch inMemoryStore.writeFiber {
  | Some(fiber) =>
    await fiber
    await inMemoryStore->flush
  | None => ()
  }
}

let prepareRollbackDiff = async (
  inMemoryStore: t,
  ~persistence: Persistence.t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
) => {
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
