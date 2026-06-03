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
  // Holds the effect outputs available for in-memory cache reads. Swapped into
  // `pendingDict` while a write is in flight (see snapshotEffects).
  mutable dict: dict<Internal.effectOutput>,
  // Outputs of the in-flight write, kept readable until the write completes so
  // the cache stays warm without growing the live dict after a commit.
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
  // Last checkpoint applied in memory (processing frontier). Runs ahead of
  // committedCheckpointId while the persistence cycle writes in the background.
  mutable processedCheckpointId: Internal.checkpointId,
  // Batches processed in memory but not yet written. The cycle drains them,
  // splitting at any change in isInReorgThreshold so each write is consistent.
  mutable processedBatches: array<Batch.t>,
  // The single in-flight write loop, None when idle. Strictly one at a time.
  mutable writeFiber: option<promise<unit>>,
  // A failed background write is surfaced at the next batch boundary / flush.
  mutable persistenceError: option<exn>,
  // Resolved after every commit so capacity/flush waiters can re-evaluate.
  mutable commitWaiters: array<unit => unit>,
  // Static for the store's lifetime - only the persistence cycle reads them.
  persistence: Persistence.t,
  config: Config.t,
  // Latest metadata staged per chain. Kept to detect whether a freshly staged
  // value actually changed (so an unchanged restage doesn't trigger a write).
  mutable chainMeta: dict<InternalTable.Chains.metaFields>,
  // Set when chainMeta changed since the last persisted write. A batch write
  // folds the snapshot in for free; otherwise it flushes on the throttle.
  mutable chainMetaDirty: bool,
  // Bounds how often a metadata-only write hits the db when no batches flow.
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

// The store may hold up to this many uncommitted changes before processing has
// to wait for the persistence cycle to free capacity.
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

// Effect cache read that also consults the in-flight write's pending values.
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

// Drains the leading run of processed batches that share isInReorgThreshold and
// accumulates them into one persistence object in a single pass. Batches past a
// change in isInReorgThreshold stay queued for the next write, so a single write
// never mixes history-saving modes. The caller (runOneWrite) only invokes this
// when processedBatches is non-empty, so the first element is safe to read.
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
    // Once a batch lands in rest (the reorg-threshold boundary), every later one
    // follows it, preserving order.
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

// Captures the effects to persist, moving the live dict into pendingDict so its
// values stay readable while the write runs, then starts a fresh live dict.
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

  // Snapshot a copy before any await: the batch write reads chainMetaData later,
  // inside the transaction, so it must not observe values staged meanwhile. A
  // restage during the write re-sets the flag and is rewritten next iteration.
  let chainMetaData = if inMemoryStore.chainMetaDirty {
    inMemoryStore.chainMetaDirty = false
    Some(inMemoryStore.chainMeta->Utils.Dict.shallowCopy)
  } else {
    None
  }

  switch inMemoryStore.processedBatches {
  | [] =>
    // No batch to write, only metadata. Runs inside the single write loop, so it
    // can't race a batch write, but uses a cheap upsert instead of a transaction.
    switch chainMetaData {
    | Some(chainsData) =>
      await persistence.storage.setChainMeta(chainsData)->Utils.Promise.ignoreValue
    | None => ()
    }
  | _ =>
    let committedCheckpointId = inMemoryStore.committedCheckpointId
    let batch = inMemoryStore->drainBatchRun
    // The run's last checkpoint - entity changes above it belong to later batches
    // (a different isInReorgThreshold) and stay queued for the next write.
    let upToCheckpointId = switch batch.checkpointIds->Utils.Array.last {
    | Some(checkpointId) => checkpointId
    | None => committedCheckpointId
    }

    // rawEvents and the effect cache aren't gated by isInReorgThreshold, so they're
    // flushed in full with this write rather than split at the run boundary.
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
  // Date is boxed - compare epoch ms rather than the object identity.
  a.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime) ==
    b.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime)

// Stages the latest chain metadata, marking it dirty only when a value actually
// changed so an unchanged restage is a no-op. A batch write carries the snapshot
// for free; with no batch in flight it flushes on the throttle.
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

// Records a processed batch in memory and triggers the background persistence
// cycle. Returns immediately - the db write happens off the processing path.
let commitBatch = (inMemoryStore: t, ~batch: Batch.t) => {
  inMemoryStore.processedBatches->Array.push(batch)->ignore
  switch batch.checkpointIds->Utils.Array.last {
  | Some(checkpointId) => inMemoryStore.processedCheckpointId = checkpointId
  | None => ()
  }
  inMemoryStore->kick
}

// Blocks the next batch until the store holds fewer than keepLatestChangesLimit
// changes, freeing committed changes first and awaiting commits as a last resort.
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

    // What's left is uncommitted. Only wait if the cycle can actually free it by
    // writing a queued batch - otherwise (e.g. a large rollback diff staged
    // without a batch) waiting would deadlock, so let processing proceed instead.
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

// Awaits until everything processed in memory is persisted to the db.
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
