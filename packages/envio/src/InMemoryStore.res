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
  mutable pendingDict: option<dict<Internal.effectOutput>>,
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
  // Per-batch checkpoint metadata accumulated since the last write started.
  mutable pendingBatches: array<Batch.t>,
  // The single in-flight write loop, None when idle. Strictly one at a time.
  mutable writeFiber: option<promise<unit>>,
  // A failed background write is surfaced at the next batch boundary / flush.
  mutable persistenceError: option<exn>,
  // Resolved after every commit so capacity/flush waiters can re-evaluate.
  mutable commitWaiters: array<unit => unit>,
  mutable persistence: option<Persistence.t>,
  mutable config: option<Config.t>,
  mutable isInReorgThreshold: bool,
  // Tail of the serialized db-write queue. Keeps background batch writes and the
  // throttled chain-metadata writes from touching the same rows concurrently.
  mutable dbWriteTail: promise<unit>,
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
  processedCheckpointId: committedCheckpointId,
  pendingBatches: [],
  writeFiber: None,
  persistenceError: None,
  commitWaiters: [],
  persistence: None,
  config: None,
  isInReorgThreshold: false,
  dbWriteTail: Promise.resolve(),
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
      pendingDict: None,
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
  | None =>
    switch inMemTable.pendingDict {
    | Some(pending) => pending->Utils.Dict.dangerouslyGetNonOption(key)
    | None => None
    }
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

// Runs fn after any pending db write completes, blocking subsequent db writes
// until it finishes, so writes to shared tables never overlap.
let serializeDbWrite = (inMemoryStore: t, fn: unit => promise<'a>): promise<'a> => {
  let run = inMemoryStore.dbWriteTail->Promise.then(_ => fn())
  inMemoryStore.dbWriteTail =
    run->Promise.then(_ => Promise.resolve())->Promise.catch(_ => Promise.resolve())
  run
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

let mergePendingBatches = (pendingBatches: array<Batch.t>): Batch.t => {
  let progressedChainsById = Dict.make()
  let totalBatchSize = ref(0)
  pendingBatches->Array.forEach(batch => {
    batch.progressedChainsById->Utils.Dict.forEachWithKey((chainAfterBatch, key) =>
      progressedChainsById->Dict.set(key, chainAfterBatch)
    )
    totalBatchSize := totalBatchSize.contents + batch.totalBatchSize
  })
  {
    totalBatchSize: totalBatchSize.contents,
    items: [],
    progressedChainsById,
    checkpointIds: pendingBatches->Belt.Array.map(b => b.checkpointIds)->Belt.Array.concatMany,
    checkpointChainIds: pendingBatches
    ->Belt.Array.map(b => b.checkpointChainIds)
    ->Belt.Array.concatMany,
    checkpointBlockNumbers: pendingBatches
    ->Belt.Array.map(b => b.checkpointBlockNumbers)
    ->Belt.Array.concatMany,
    checkpointBlockHashes: pendingBatches
    ->Belt.Array.map(b => b.checkpointBlockHashes)
    ->Belt.Array.concatMany,
    checkpointEventsProcessed: pendingBatches
    ->Belt.Array.map(b => b.checkpointEventsProcessed)
    ->Belt.Array.concatMany,
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
    inMemTable.pendingDict = Some(dict)
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

  let committedCheckpointId = inMemoryStore.committedCheckpointId
  let pendingBatches = inMemoryStore.pendingBatches
  inMemoryStore.pendingBatches = []
  let batch = mergePendingBatches(pendingBatches)
  let snapshotCheckpointId = switch batch.checkpointIds->Utils.Array.last {
  | Some(checkpointId) => checkpointId
  | None => committedCheckpointId
  }

  let rawEvents = inMemoryStore.rawEvents
  inMemoryStore.rawEvents = []
  let rollback = inMemoryStore.rollback
  inMemoryStore.rollback = None

  let updatedEntities = persistence.allEntities->Array.filterMap(entityConfig => {
    let table = inMemoryStore->getInMemTable(~entityConfig)
    let changes = table->InMemoryTable.Entity.snapshotChanges(~committedCheckpointId)
    if changes->Utils.Array.isEmpty {
      None
    } else {
      Some(({entityConfig, changes}: Persistence.updatedEntity))
    }
  })
  let updatedEffectsCache = snapshotEffects(inMemoryStore, ~cache)

  await inMemoryStore->serializeDbWrite(() =>
    persistence.storage.writeBatch(
      ~batch,
      ~rawEvents,
      ~rollback,
      ~isInReorgThreshold=inMemoryStore.isInReorgThreshold,
      ~config,
      ~allEntities=persistence.allEntities,
      ~updatedEntities,
      ~updatedEffectsCache,
    )
  )

  inMemoryStore.committedCheckpointId = snapshotCheckpointId
  inMemoryStore.effects->Utils.Dict.forEach(inMemTable => inMemTable.pendingDict = None)
}

let runWriteLoop = async (inMemoryStore: t) => {
  switch (inMemoryStore.persistence, inMemoryStore.config) {
  | (Some(persistence), Some(config)) =>
    while (
      inMemoryStore.processedCheckpointId > inMemoryStore.committedCheckpointId &&
        inMemoryStore.persistenceError->Option.isNone
    ) {
      try {
        await runOneWrite(inMemoryStore, ~persistence, ~config)
        inMemoryStore->wakeCommitWaiters
      } catch {
      | exn => inMemoryStore.persistenceError = Some(exn)
      }
    }
  | _ => ()
  }
  inMemoryStore.writeFiber = None
  inMemoryStore->wakeCommitWaiters
}

let kick = (inMemoryStore: t) =>
  if (
    inMemoryStore.writeFiber->Option.isNone &&
    inMemoryStore.persistenceError->Option.isNone &&
    inMemoryStore.processedCheckpointId > inMemoryStore.committedCheckpointId
  ) {
    inMemoryStore.writeFiber = Some(runWriteLoop(inMemoryStore))
  }

// Records a processed batch in memory and triggers the background persistence
// cycle. Returns immediately - the db write happens off the processing path.
let commitBatch = (
  inMemoryStore: t,
  ~persistence: Persistence.t,
  ~batch: Batch.t,
  ~config,
  ~isInReorgThreshold,
) => {
  inMemoryStore.persistence = Some(persistence)
  inMemoryStore.config = Some(config)
  inMemoryStore.isInReorgThreshold = isInReorgThreshold
  inMemoryStore.pendingBatches->Array.push(batch)->ignore
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
    if inMemoryStore->getChangesCount >= keepLatestChangesLimit {
      // What's left is uncommitted, so wait for the cycle to persist more.
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

// Before a rollback: let the in-flight write finish so committedCheckpointId
// reflects the db, then reset the processing frontier to it. Uncommitted state
// is discarded by prepareRollbackDiff and reprocessed from the committed point.
let drainForRollback = async (inMemoryStore: t) => {
  switch inMemoryStore.writeFiber {
  | Some(fiber) => await fiber
  | None => ()
  }
  inMemoryStore.pendingBatches = []
  inMemoryStore.processedCheckpointId = inMemoryStore.committedCheckpointId
  switch inMemoryStore.persistenceError {
  | Some(exn) => throw(exn)
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
