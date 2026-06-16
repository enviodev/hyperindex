// Operations on the in-memory store, whose state now lives on IndexerState:
// entity/effect tables, the pending-write queue and the write loop.

// Max uncommitted entity/effect changes plus unwritten batch items before
// processing must wait for the cycle to free capacity.
let keepLatestChangesLimit = Env.inMemoryObjectsTarget

let getEffectInMemTable = (inMemoryStore: IndexerState.t, ~effect: Internal.effect) => {
  let key = effect.name
  switch inMemoryStore.effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table: IndexerState.effectCacheInMemTable = {
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

let hasEffectOutput = (inMemTable: IndexerState.effectCacheInMemTable, key) =>
  switch inMemTable.dict->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(Set(_)) => true
  | Some(Delete(_)) | None => false
  }

// Returns the raw output. The output is itself an option for effects with an
// optional output, so it must never be wrapped in another option here: Some(None)
// is encoded as the nested-option sentinel and would leak to the handler.
let getEffectOutputUnsafe = (
  inMemTable: IndexerState.effectCacheInMemTable,
  key,
): Internal.effectOutput =>
  switch inMemTable.dict->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(Set({entity: output})) => output
  | Some(Delete(_)) | None => %raw(`undefined`)
  }

// Records a handler output. Persisted on the next write only when shouldCache;
// otherwise kept in memory (re-run on a later miss) but never written to the db.
let setEffectOutput = (
  inMemTable: IndexerState.effectCacheInMemTable,
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
let initEffectOutputFromDb = (inMemTable: IndexerState.effectCacheInMemTable, ~cacheKey, ~output) =>
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
  inMemTable: IndexerState.effectCacheInMemTable,
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
  inMemoryStore: IndexerState.t,
  ~entityConfig: Internal.entityConfig,
): InMemoryTable.Entity.t => {
  inMemoryStore.entities->IndexerState.EntityTables.get(~entityName=entityConfig.name)
}

let isRollingBack = (inMemoryStore: IndexerState.t) => inMemoryStore.rollback !== None

let getChangesCount = (inMemoryStore: IndexerState.t) => {
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

let wakeCommitWaiters = (inMemoryStore: IndexerState.t) => {
  let waiters = inMemoryStore.commitWaiters
  inMemoryStore.commitWaiters = []
  waiters->Array.forEach(resolve => resolve())
}

let waitForCommit = (inMemoryStore: IndexerState.t): promise<unit> =>
  Promise.make((resolve, _) => {
    inMemoryStore.commitWaiters->Array.push(resolve)->ignore
  })

// Merges the leading run of batches sharing isInReorgThreshold into one batch;
// the rest stay queued for the next write. Caller guarantees processedBatches
// is non-empty.
let drainBatchRun = (inMemoryStore: IndexerState.t): Batch.t => {
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
let snapshotEffects = (inMemoryStore: IndexerState.t, ~cache): array<
  Persistence.updatedEffectCache,
> => {
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

let runOneWrite = async (inMemoryStore: IndexerState.t) => {
  let persistence = inMemoryStore.persistence
  let config = inMemoryStore.config
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

    switch rollback {
    | Some({progressBlockNumberByChainId}) if RollbackCommit.callbacks->Utils.Array.notEmpty =>
      await RollbackCommit.fire(~progressBlockNumberByChainId)
    | _ => ()
    }
  }
}

let hasPendingWrite = (inMemoryStore: IndexerState.t) =>
  inMemoryStore.processedBatches->Utils.Array.notEmpty || inMemoryStore.chainMetaDirty

let runWriteLoop = async (inMemoryStore: IndexerState.t) => {
  while inMemoryStore->hasPendingWrite && !inMemoryStore.hasFailedWrite {
    try {
      await runOneWrite(inMemoryStore)
      inMemoryStore->wakeCommitWaiters
    } catch {
    | exn =>
      inMemoryStore.hasFailedWrite = true
      inMemoryStore.onError(exn->ErrorHandling.make(~msg="Failed writing batch to the database"))
    }
  }
  inMemoryStore.writeFiber = None
  inMemoryStore->wakeCommitWaiters
}

let kick = (inMemoryStore: IndexerState.t) =>
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
let setChainMeta = (
  inMemoryStore: IndexerState.t,
  chainsData: dict<InternalTable.Chains.metaFields>,
) => {
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
let commitBatch = (inMemoryStore: IndexerState.t, ~batch: Batch.t) => {
  inMemoryStore.processedBatches->Array.push(batch)->ignore
  switch batch.checkpointIds->Utils.Array.last {
  | Some(checkpointId) => inMemoryStore.processedCheckpointId = checkpointId
  | None => ()
  }
  inMemoryStore->kick
}

// Drops committed entity and effect entries across all tables. With
// keepLoadedFromDb, entries seeded from a db read are spared.
let dropCommitted = (inMemoryStore: IndexerState.t, ~keepLoadedFromDb) => {
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

// Blocks until the store holds fewer than keepLatestChangesLimit changes,
// freeing committed changes first and awaiting commits as a last resort.
let rec awaitCapacity = async (inMemoryStore: IndexerState.t) => {
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
let rec flush = async (inMemoryStore: IndexerState.t) => {
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
  inMemoryStore: IndexerState.t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
  ~progressBlockNumberByChainId,
) => {
  let persistence = inMemoryStore.persistence
  inMemoryStore.entities = IndexerState.EntityTables.make(inMemoryStore.allEntities)
  inMemoryStore.effects = Dict.make()
  inMemoryStore.rollback = Some({
    targetCheckpointId: rollbackTargetCheckpointId,
    diffCheckpointId: rollbackDiffCheckpointId,
    progressBlockNumberByChainId,
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

    let restoredEntities =
      restoredEntitiesResult
      ->S.parseOrThrow(entityConfig.table->Table.pgRowsSchema)
      ->(Utils.magic: array<unknown> => array<Internal.entity>)

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

let setBatchDcs = (inMemoryStore: IndexerState.t, ~batch: Batch.t) => {
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
