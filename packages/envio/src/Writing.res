// The write loop: drains the processed-batch queue and staged chain metadata to
// storage off the processing path. A peer to ChainFetching/BatchProcessing/
// Rollback, but data-driven — `schedule` kicks a single write fiber whenever
// there's pending work, and processing waits on it through awaitCapacity/flush.
// State mutations go through IndexerState's domain operations.

// Max uncommitted entity/effect changes plus unwritten batch items before
// processing must wait for the cycle to free capacity.
let keepLatestChangesLimit = Env.inMemoryObjectsTarget

let getChangesCount = (state: IndexerState.t) => {
  let total = ref(0.)
  state
  ->IndexerState.allEntities
  ->Array.forEach(entityConfig => {
    total := total.contents +. (state->InMemoryStore.getInMemTable(~entityConfig)).changesCount
  })
  state
  ->IndexerState.effectState
  ->EffectState.forEach(inMemTable => {
    total := total.contents +. inMemTable.changesCount
  })
  state
  ->IndexerState.processedBatches
  ->Array.forEach(batch => {
    total := total.contents +. batch.totalBatchSize->Int.toFloat
  })
  total.contents
}

let waitForCommit = (state: IndexerState.t): promise<unit> =>
  Promise.make((resolve, _) => {
    state->IndexerState.addCommitWaiter(resolve)
  })

// Captures the cache:true outputs to persist. The dict is left intact — entries
// stay warm and are reclaimed later by dropCommittedEffects once committed.
let snapshotEffects = (state: IndexerState.t, ~cache): array<Persistence.updatedEffectCache> => {
  let acc = []
  state
  ->IndexerState.effectState
  ->EffectState.forEach(inMemTable => {
    let {idsToStore, dict, effect, invalidationsCount, scope, table} = inMemTable
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
      let tableName = table.tableName
      let effectCacheRecord = switch cache->Utils.Dict.dangerouslyGetNonOption(tableName) {
      | Some(c) => c
      | None =>
        let c: Persistence.effectCacheRecord = {effectName, scope, tableName, count: 0}
        cache->Dict.set(tableName, c)
        c
      }
      let shouldInitialize = effectCacheRecord.count === 0
      effectCacheRecord.count = effectCacheRecord.count + items->Array.length - invalidationsCount
      inMemTable->EffectState.commitCacheCount(~count=effectCacheRecord.count)
      acc
      ->Array.push(
        (
          {
            table,
            itemSchema: effect.storageMeta.itemSchema,
            items,
            shouldInitialize,
          }: Persistence.updatedEffectCache
        ),
      )
      ->ignore
    }
    inMemTable.idsToStore = []
    inMemTable.invalidationsCount = 0
  })
  acc
}

let runOneWrite = async (state: IndexerState.t) => {
  let persistence = state->IndexerState.persistence
  let config = state->IndexerState.config
  let cache = switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    JsError.throwWithMessage(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) => cache
  }

  // Snapshot before the await: the batch write reads this later, in-transaction.
  let chainMetaData = state->IndexerState.takeChainMetaSnapshot

  switch state->IndexerState.processedBatches {
  | [] =>
    // Metadata only: a cheap upsert, still serialized by the single write loop.
    switch chainMetaData {
    | Some(chainsData) =>
      await persistence.storage.setChainMeta(chainsData)->Utils.Promise.ignoreValue
    | None => ()
    }
  | _ =>
    let committedCheckpointId = state->IndexerState.committedCheckpointId
    let batch = state->IndexerState.drainBatchRun
    // The run's last checkpoint; entity changes above it stay queued for the next write.
    let upToCheckpointId = switch batch.checkpointIds->Utils.Array.last {
    | Some(checkpointId) => checkpointId
    | None => committedCheckpointId
    }

    let rollback = state->IndexerState.takeRollback

    let updatedEntities = persistence.allEntities->Array.filterMap(entityConfig => {
      let table = state->InMemoryStore.getInMemTable(~entityConfig)
      let changes =
        table->InMemoryTable.Entity.snapshotChanges(~committedCheckpointId, ~upToCheckpointId)
      if changes->Utils.Array.isEmpty {
        None
      } else {
        Some(({entityConfig, changes}: Persistence.updatedEntity))
      }
    })
    let updatedEffectsCache = snapshotEffects(state, ~cache)

    let writtenEntityNames = Utils.Set.make()
    updatedEntities->Array.forEach(({entityConfig}) =>
      writtenEntityNames->Utils.Set.add(entityConfig.name)->ignore
    )
    let pruneTargets = PruneStaleHistory.select(
      state,
      ~writtenEntityNames,
      ~isRollback=rollback->Option.isSome,
    )

    // The prune runs concurrently with the batch write, but only for entities
    // absent from it, so they never touch the same history table. Both must be
    // awaited before the next write starts, otherwise a still-running prune
    // could overlap the next batch's history writes and lose an anchor (which
    // breaks a later rollback). Rollback writes touch every history table, so
    // they get no concurrent prune at all.
    let _ = await Promise.all2((
      persistence.storage.writeBatch(
        ~batch,
        ~rollback,
        ~isInReorgThreshold=batch.isInReorgThreshold,
        ~config,
        ~allEntities=persistence.allEntities,
        ~updatedEntities,
        ~updatedEffectsCache,
        ~chainMetaData,
        ~onWrite=(~storage, ~timeSeconds) =>
          state->IndexerState.recordStorageWrite(~storage, ~timeSeconds),
      ),
      PruneStaleHistory.runConcurrent(state, ~targets=pruneTargets),
    ))

    state->IndexerState.markCommitted(~upToCheckpointId)

    switch rollback {
    | Some({progressBlockNumberByChainId}) if RollbackCommit.callbacks->Utils.Array.notEmpty =>
      await RollbackCommit.fire(~progressBlockNumberByChainId)
    | _ => ()
    }

    // Entities starved of the concurrent prune (eg written in every batch) are
    // pruned here with no other pg writer running.
    await PruneStaleHistory.runForced(state, ~targets=pruneTargets)
  }
}

let hasPendingWrite = (state: IndexerState.t) =>
  state->IndexerState.processedBatches->Utils.Array.notEmpty || state->IndexerState.chainMetaDirty

let runWriteLoop = async (state: IndexerState.t) => {
  while state->hasPendingWrite && !(state->IndexerState.hasFailedWrite) {
    try {
      await runOneWrite(state)
      state->IndexerState.wakeCommitWaiters
    } catch {
    | exn => state->IndexerState.recordWriteFailure(exn)
    }
  }
  state->IndexerState.endWriteFiber
  state->IndexerState.wakeCommitWaiters
}

// Kicks the single write fiber if there's pending work and one isn't running.
let schedule = (state: IndexerState.t) =>
  if (
    state->IndexerState.writeFiber->Option.isNone &&
    !(state->IndexerState.hasFailedWrite) &&
    state->hasPendingWrite
  ) {
    state->IndexerState.beginWriteFiber(runWriteLoop(state))
  }

// Stages chain metadata and throttles a metadata-only write when no batches flow.
let setChainMeta = (state: IndexerState.t, chainsData: dict<InternalTable.Chains.metaFields>) => {
  state->IndexerState.stageChainMeta(chainsData)
  if state->IndexerState.chainMetaDirty {
    state
    ->IndexerState.chainMetaThrottler
    ->Throttler.schedule(() => {
      state->schedule
      Promise.resolve()
    })
  }
}

// Queues a processed batch and kicks the cycle. Returns immediately; the write
// happens off the processing path.
let commitBatch = (state: IndexerState.t, ~batch: Batch.t) => {
  state->IndexerState.queueProcessedBatch(~batch)
  state->schedule
}

// Drops committed entity and effect entries across all tables. With
// keepLoadedFromDb, entries seeded from a db read are spared.
let dropCommitted = (state: IndexerState.t, ~keepLoadedFromDb) => {
  let committedCheckpointId = state->IndexerState.committedCheckpointId
  state
  ->IndexerState.allEntities
  ->Array.forEach(entityConfig =>
    state
    ->InMemoryStore.getInMemTable(~entityConfig)
    ->InMemoryTable.Entity.dropCommittedChanges(~committedCheckpointId, ~keepLoadedFromDb)
  )
  state
  ->IndexerState.effectState
  ->EffectState.forEach(inMemTable =>
    inMemTable->InMemoryStore.dropCommittedEffects(~committedCheckpointId, ~keepLoadedFromDb)
  )
}

// Blocks until the store holds fewer than keepLatestChangesLimit changes,
// freeing committed changes first and awaiting commits as a last resort.
let rec awaitCapacity = async (state: IndexerState.t) => {
  // After a failed write nothing will free capacity, so bail instead of waiting
  // on a commit that won't come (the error already went to onError).
  if !(state->IndexerState.hasFailedWrite) && state->getChangesCount >= keepLatestChangesLimit {
    // Drop committed writes first, sparing db-loaded entries (explicitly
    // requested, so likelier to be read again).
    state->dropCommitted(~keepLoadedFromDb=true)

    // Still over: drop the db-loaded entries too.
    if state->getChangesCount >= keepLatestChangesLimit {
      state->dropCommitted(~keepLoadedFromDb=false)
    }

    // Still over: what's left is uncommitted. Only wait if a queued batch can
    // free it; otherwise (e.g. a large rollback diff with no batch) waiting
    // would deadlock, so let processing proceed.
    if (
      state->getChangesCount >= keepLatestChangesLimit &&
        state->IndexerState.processedBatches->Utils.Array.notEmpty
    ) {
      state->schedule
      await state->waitForCommit
      await state->awaitCapacity
    }
  }
}

// Awaits until everything processed is persisted. On a failed write we stop
// draining (onError already surfaced it) rather than throw.
let rec flush = async (state: IndexerState.t) => {
  if !(state->IndexerState.hasFailedWrite) {
    state->schedule
    switch state->IndexerState.writeFiber {
    | Some(fiber) =>
      await fiber
      await state->flush
    | None => ()
    }
  }
}
