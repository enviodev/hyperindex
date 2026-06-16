// The write loop: drains the processed-batch queue and staged chain metadata to
// storage off the processing path. A peer to ChainFetching/BatchProcessing/
// Rollback, but data-driven — `schedule` kicks a single write fiber whenever
// there's pending work, and processing waits on it through awaitCapacity/flush.

// Max uncommitted entity/effect changes plus unwritten batch items before
// processing must wait for the cycle to free capacity.
let keepLatestChangesLimit = Env.inMemoryObjectsTarget

let getChangesCount = (state: IndexerState.t) => {
  let total = ref(0.)
  state.allEntities->Array.forEach(entityConfig => {
    total := total.contents +. (state->InMemoryStore.getInMemTable(~entityConfig)).changesCount
  })
  state.effects->Utils.Dict.forEach(inMemTable => {
    total := total.contents +. inMemTable.changesCount
  })
  state.processedBatches->Array.forEach(batch => {
    total := total.contents +. batch.totalBatchSize->Int.toFloat
  })
  total.contents
}

let wakeCommitWaiters = (state: IndexerState.t) => {
  let waiters = state.commitWaiters
  state.commitWaiters = []
  waiters->Array.forEach(resolve => resolve())
}

let waitForCommit = (state: IndexerState.t): promise<unit> =>
  Promise.make((resolve, _) => {
    state.commitWaiters->Array.push(resolve)->ignore
  })

// Merges the leading run of batches sharing isInReorgThreshold into one batch;
// the rest stay queued for the next write. Caller guarantees processedBatches
// is non-empty.
let drainBatchRun = (state: IndexerState.t): Batch.t => {
  let all = state.processedBatches
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
  state.processedBatches = rest

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
let snapshotEffects = (state: IndexerState.t, ~cache): array<Persistence.updatedEffectCache> => {
  let acc = []
  state.effects->Utils.Dict.forEach(inMemTable => {
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

let runOneWrite = async (state: IndexerState.t) => {
  let persistence = state.persistence
  let config = state.config
  let cache = switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    JsError.throwWithMessage(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) => cache
  }

  // Copy before the await: the batch write reads this later, in-transaction. A
  // restage during the write re-dirties the flag and is rewritten next iteration.
  let chainMetaData = if state.chainMetaDirty {
    state.chainMetaDirty = false
    Some(state.chainMeta->Utils.Dict.shallowCopy)
  } else {
    None
  }

  switch state.processedBatches {
  | [] =>
    // Metadata only: a cheap upsert, still serialized by the single write loop.
    switch chainMetaData {
    | Some(chainsData) =>
      await persistence.storage.setChainMeta(chainsData)->Utils.Promise.ignoreValue
    | None => ()
    }
  | _ =>
    let committedCheckpointId = state.committedCheckpointId
    let batch = state->drainBatchRun
    // The run's last checkpoint; entity changes above it stay queued for the next write.
    let upToCheckpointId = switch batch.checkpointIds->Utils.Array.last {
    | Some(checkpointId) => checkpointId
    | None => committedCheckpointId
    }

    let rollback = state.rollback
    state.rollback = None

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

    state.committedCheckpointId = upToCheckpointId

    switch rollback {
    | Some({progressBlockNumberByChainId}) if RollbackCommit.callbacks->Utils.Array.notEmpty =>
      await RollbackCommit.fire(~progressBlockNumberByChainId)
    | _ => ()
    }
  }
}

let hasPendingWrite = (state: IndexerState.t) =>
  state.processedBatches->Utils.Array.notEmpty || state.chainMetaDirty

let runWriteLoop = async (state: IndexerState.t) => {
  while state->hasPendingWrite && !state.hasFailedWrite {
    try {
      await runOneWrite(state)
      state->wakeCommitWaiters
    } catch {
    | exn =>
      state.hasFailedWrite = true
      state.onError(exn->ErrorHandling.make(~msg="Failed writing batch to the database"))
    }
  }
  state.writeFiber = None
  state->wakeCommitWaiters
}

// Kicks the single write fiber if there's pending work and one isn't running.
let schedule = (state: IndexerState.t) =>
  if state.writeFiber->Option.isNone && !state.hasFailedWrite && state->hasPendingWrite {
    state.writeFiber = Some(runWriteLoop(state))
  }

let metaFieldsEqual = (a: InternalTable.Chains.metaFields, b: InternalTable.Chains.metaFields) =>
  a.firstEventBlockNumber == b.firstEventBlockNumber &&
  a.latestFetchedBlockNumber == b.latestFetchedBlockNumber &&
  a.isHyperSync == b.isHyperSync &&
  // Date is boxed; compare epoch ms.
  a.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime) ==
    b.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime)

// Stages chain metadata, dirtying only on a real change so restages are no-ops.
let setChainMeta = (state: IndexerState.t, chainsData: dict<InternalTable.Chains.metaFields>) => {
  chainsData->Utils.Dict.forEachWithKey((meta, chainId) => {
    let changed = switch state.chainMeta->Utils.Dict.dangerouslyGetNonOption(chainId) {
    | Some(prev) => !metaFieldsEqual(meta, prev)
    | None => true
    }
    if changed {
      state.chainMeta->Dict.set(chainId, meta)
      state.chainMetaDirty = true
    }
  })
  if state.chainMetaDirty {
    state.chainMetaThrottler->Throttler.schedule(() => {
      state->schedule
      Promise.resolve()
    })
  }
}

// Queues a processed batch and kicks the cycle. Returns immediately; the write
// happens off the processing path.
let commitBatch = (state: IndexerState.t, ~batch: Batch.t) => {
  state.processedBatches->Array.push(batch)->ignore
  switch batch.checkpointIds->Utils.Array.last {
  | Some(checkpointId) => state.processedCheckpointId = checkpointId
  | None => ()
  }
  state->schedule
}

// Drops committed entity and effect entries across all tables. With
// keepLoadedFromDb, entries seeded from a db read are spared.
let dropCommitted = (state: IndexerState.t, ~keepLoadedFromDb) => {
  let committedCheckpointId = state.committedCheckpointId
  state.allEntities->Array.forEach(entityConfig =>
    state
    ->InMemoryStore.getInMemTable(~entityConfig)
    ->InMemoryTable.Entity.dropCommittedChanges(~committedCheckpointId, ~keepLoadedFromDb)
  )
  state.effects->Utils.Dict.forEach(inMemTable =>
    inMemTable->InMemoryStore.dropCommittedEffects(~committedCheckpointId, ~keepLoadedFromDb)
  )
}

// Blocks until the store holds fewer than keepLatestChangesLimit changes,
// freeing committed changes first and awaiting commits as a last resort.
let rec awaitCapacity = async (state: IndexerState.t) => {
  // After a failed write nothing will free capacity, so bail instead of waiting
  // on a commit that won't come (the error already went to onError).
  if !state.hasFailedWrite && state->getChangesCount >= keepLatestChangesLimit {
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
        state.processedBatches->Utils.Array.notEmpty
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
  if !state.hasFailedWrite {
    state->schedule
    switch state.writeFiber {
    | Some(fiber) =>
      await fiber
      await state->flush
    | None => ()
    }
  }
}
