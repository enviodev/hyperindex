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
  // Cache keys whose handler output is persisted on the next write. Drained
  // each write; eviction is driven by the per-entry checkpointId instead.
  mutable idsToStore: array<string>,
  mutable invalidationsCount: int,
  // Each entry is stamped with the checkpoint that referenced it (or
  // loadedFromDbCheckpointId for db reads), so committed entries can be
  // dropped once persisted/re-derivable, mirroring entity changes.
  mutable dict: dict<Change.t<Internal.effectOutput>>,
  mutable changesCount: float,
  effect: Internal.effect,
}

type t = {
  allEntities: array<Internal.entityConfig>,
  mutable entities: dict<InMemoryTable.Entity.t>,
  mutable effects: dict<effectCacheInMemTable>,
  mutable rollback: option<Persistence.rollback>,
  // Last checkpoint persisted to the db.
  mutable committedCheckpointId: Internal.checkpointId,
  // Processing frontier; runs ahead of committedCheckpointId while writes lag.
  mutable processedCheckpointId: Internal.checkpointId,
  // Processed but unwritten. The cycle drains them, splitting each write at a
  // change in isInReorgThreshold so it never mixes history-saving modes.
  mutable processedBatches: array<Batch.t>,
  // The single in-flight write loop, None when idle.
  mutable writeFiber: option<promise<unit>>,
  // Set once a write throws, to stop the loop. The error itself goes to onError.
  mutable hasFailedWrite: bool,
  // Called once on a write failure; the caller decides what to do (exit).
  onError: exn => unit,
  // Resolved after every commit so capacity/flush waiters can re-evaluate.
  mutable commitWaiters: array<unit => unit>,
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
  ~onError: exn => unit,
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
    entities: EntityTables.make(entities),
    effects: Dict.make(),
    rollback: None,
    committedCheckpointId,
    processedCheckpointId: committedCheckpointId,
    processedBatches: [],
    writeFiber: None,
    hasFailedWrite: false,
    onError,
    commitWaiters: [],
    persistence,
    config,
    chainMeta: Dict.make(),
    chainMetaDirty: false,
    chainMetaThrottler,
  }
}

// Max uncommitted entity/effect changes plus unwritten batch items before
// processing must wait for the cycle to free capacity.
let keepLatestChangesLimit = Env.inMemoryObjectsTarget

let getEffectInMemTable = (inMemoryStore: t, ~effect: Internal.effect) => {
  let key = effect.name
  switch inMemoryStore.effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table = {
      idsToStore: [],
      dict: Dict.make(),
      changesCount: 0.,
      invalidationsCount: 0,
      effect,
    }
    inMemoryStore.effects->Dict.set(key, table)
    table
  }
}

let getEffectOutput = (inMemTable: effectCacheInMemTable, key) =>
  switch inMemTable.dict->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(Set({entity: output})) => Some(output)
  | Some(Delete(_)) | None => None
  }

// Records a handler output. Persisted on the next write only when shouldCache;
// otherwise kept in memory (re-run on a later miss) but never written to the db.
let setEffectOutput = (
  inMemTable: effectCacheInMemTable,
  ~checkpointId,
  ~cacheKey,
  ~output,
  ~shouldCache,
) => {
  switch inMemTable.dict->Utils.Dict.dangerouslyGetNonOption(cacheKey) {
  | Some(_) => ()
  | None => inMemTable.changesCount = inMemTable.changesCount +. 1.
  }
  inMemTable.dict->Dict.set(cacheKey, Set({entityId: cacheKey, entity: output, checkpointId}))
  if shouldCache {
    inMemTable.idsToStore->Array.push(cacheKey)->ignore
  }
}

// Seeds an entry from a db read. Stamped with loadedFromDbCheckpointId so it's
// always droppable (re-readable from the db) and never re-persisted.
let initEffectOutputFromDb = (inMemTable: effectCacheInMemTable, ~cacheKey, ~output) =>
  if inMemTable.dict->Utils.Dict.dangerouslyGetNonOption(cacheKey)->Option.isNone {
    inMemTable.changesCount = inMemTable.changesCount +. 1.
    inMemTable.dict->Dict.set(
      cacheKey,
      Set({entityId: cacheKey, entity: output, checkpointId: Internal.loadedFromDbCheckpointId}),
    )
  }

// Frees committed entries (re-readable from the db, or re-runnable for
// cache:false). Uncommitted entries stay warm. With keepLoadedFromDb, entries
// seeded from a db read are spared. Mirrors entity dropCommittedChanges.
let dropCommittedEffects = (
  inMemTable: effectCacheInMemTable,
  ~committedCheckpointId,
  ~keepLoadedFromDb,
) => {
  let keysToDelete = []
  inMemTable.dict->Utils.Dict.forEachWithKey((change, key) => {
    let checkpointId = change->Change.getCheckpointId
    if (
      !(checkpointId > committedCheckpointId) &&
      !(keepLoadedFromDb && checkpointId == Internal.loadedFromDbCheckpointId)
    ) {
      keysToDelete->Array.push(key)
    }
  })
  keysToDelete->Array.forEach(key => inMemTable.dict->Utils.Dict.deleteInPlace(key))
  inMemTable.changesCount = inMemTable.changesCount -. keysToDelete->Array.length->Int.toFloat
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
  inMemoryStore.effects->Utils.Dict.forEach(inMemTable => {
    total := total.contents +. inMemTable.changesCount
  })
  inMemoryStore.processedBatches->Array.forEach(batch => {
    total := total.contents +. batch.totalBatchSize->Int.toFloat
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

// Merges the leading run of batches sharing isInReorgThreshold into one batch;
// the rest stay queued for the next write. Caller guarantees processedBatches
// is non-empty.
let drainBatchRun = (inMemoryStore: t): Batch.t => {
  let all = inMemoryStore.processedBatches
  let isInReorgThreshold = (all->Array.getUnsafe(0)).isInReorgThreshold

  let rest = []
  let progressedChainsById = Dict.make()
  let totalBatchSize = ref(0)
  let items = []
  let checkpointIds = []
  let checkpointChainIds = []
  let checkpointBlockNumbers = []
  let checkpointBlockHashes = []
  let checkpointEventsProcessed = []
  all->Array.forEach(batch => {
    // Once one batch lands in rest, all later ones follow it, preserving order.
    if rest->Utils.Array.isEmpty && batch.isInReorgThreshold == isInReorgThreshold {
      batch.progressedChainsById->Utils.Dict.forEachWithKey((chainAfterBatch, key) =>
        progressedChainsById->Dict.set(key, chainAfterBatch)
      )
      totalBatchSize := totalBatchSize.contents + batch.totalBatchSize
      items->Array.pushMany(batch.items)
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
    items,
    progressedChainsById,
    isInReorgThreshold,
    checkpointIds,
    checkpointChainIds,
    checkpointBlockNumbers,
    checkpointBlockHashes,
    checkpointEventsProcessed,
  }
}

// Captures the cache:true outputs to persist. The dict is left intact — entries
// stay warm and are reclaimed later by dropCommittedEffects once committed.
let snapshotEffects = (inMemoryStore: t, ~cache): array<Persistence.updatedEffectCache> => {
  let acc = []
  inMemoryStore.effects->Utils.Dict.forEach(inMemTable => {
    let {idsToStore, dict, effect, invalidationsCount} = inMemTable
    switch idsToStore {
    | [] => ()
    | ids =>
      let items = ids->Array.filterMap((id): option<Internal.effectCacheItem> =>
        switch dict->Dict.getUnsafe(id) {
        | Set({entity: output}) => Some({id, output})
        | Delete(_) => None
        }
      )
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
    // The run's last checkpoint; entity changes above it stay queued for the next write.
    let upToCheckpointId = switch batch.checkpointIds->Utils.Array.last {
    | Some(checkpointId) => checkpointId
    | None => committedCheckpointId
    }

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
      ~rollback,
      ~isInReorgThreshold=batch.isInReorgThreshold,
      ~config,
      ~allEntities=persistence.allEntities,
      ~updatedEntities,
      ~updatedEffectsCache,
      ~chainMetaData,
    )

    inMemoryStore.committedCheckpointId = upToCheckpointId
  }
}

let hasPendingWrite = (inMemoryStore: t) =>
  inMemoryStore.processedBatches->Utils.Array.notEmpty || inMemoryStore.chainMetaDirty

let runWriteLoop = async (inMemoryStore: t) => {
  while inMemoryStore->hasPendingWrite && !inMemoryStore.hasFailedWrite {
    try {
      await runOneWrite(
        inMemoryStore,
        ~persistence=inMemoryStore.persistence,
        ~config=inMemoryStore.config,
      )
      inMemoryStore->wakeCommitWaiters
    } catch {
    | exn =>
      inMemoryStore.hasFailedWrite = true
      inMemoryStore.onError(exn)
    }
  }
  inMemoryStore.writeFiber = None
  inMemoryStore->wakeCommitWaiters
}

let kick = (inMemoryStore: t) =>
  if (
    inMemoryStore.writeFiber->Option.isNone &&
    !inMemoryStore.hasFailedWrite &&
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

// Queues a processed batch and kicks the cycle. Returns immediately; the write
// happens off the processing path.
let commitBatch = (inMemoryStore: t, ~batch: Batch.t) => {
  inMemoryStore.processedBatches->Array.push(batch)->ignore
  switch batch.checkpointIds->Utils.Array.last {
  | Some(checkpointId) => inMemoryStore.processedCheckpointId = checkpointId
  | None => ()
  }
  inMemoryStore->kick
}

// Blocks until the store holds fewer than keepLatestChangesLimit changes,
// freeing committed changes first and awaiting commits as a last resort.
let dropCommitted = (inMemoryStore: t, ~keepLoadedFromDb) => {
  let committedCheckpointId = inMemoryStore.committedCheckpointId
  inMemoryStore.allEntities->Array.forEach(entityConfig =>
    inMemoryStore
    ->getInMemTable(~entityConfig)
    ->InMemoryTable.Entity.dropCommittedChanges(~committedCheckpointId, ~keepLoadedFromDb)
  )
  inMemoryStore.effects->Utils.Dict.forEach(inMemTable =>
    inMemTable->dropCommittedEffects(~committedCheckpointId, ~keepLoadedFromDb)
  )
}

let rec awaitCapacity = async (inMemoryStore: t) => {
  // After a failed write nothing will free capacity, so bail instead of waiting
  // on a commit that won't come (the error already went to onError).
  if !inMemoryStore.hasFailedWrite && inMemoryStore->getChangesCount >= keepLatestChangesLimit {
    // Drop committed writes first, sparing db-loaded entries (explicitly
    // requested, so likelier to be read again).
    inMemoryStore->dropCommitted(~keepLoadedFromDb=true)

    // Still over: drop the db-loaded entries too.
    if inMemoryStore->getChangesCount >= keepLatestChangesLimit {
      inMemoryStore->dropCommitted(~keepLoadedFromDb=false)
    }

    // Still over: what's left is uncommitted. Only wait if a queued batch can
    // free it; otherwise (e.g. a large rollback diff with no batch) waiting
    // would deadlock, so let processing proceed.
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

// Awaits until everything processed is persisted. On a failed write we stop
// draining (onError already surfaced it) rather than throw.
let rec flush = async (inMemoryStore: t) => {
  if !inMemoryStore.hasFailedWrite {
    inMemoryStore->kick
    switch inMemoryStore.writeFiber {
    | Some(fiber) =>
      await fiber
      await inMemoryStore->flush
    | None => ()
    }
  }
}

let prepareRollbackDiff = async (
  inMemoryStore: t,
  ~persistence: Persistence.t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
) => {
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
