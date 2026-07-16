// Entity and effect table primitives over IndexerState's in-memory store. State
// mutations route through IndexerState's domain operations; the write loop and
// capacity/flush coordination live in Writing.

let getInMemTable = (
  state: IndexerState.t,
  ~entityConfig: Internal.entityConfig,
): InMemoryTable.Entity.t =>
  state->IndexerState.entities->IndexerState.EntityTables.get(~entityName=entityConfig.name)

let getEffectInMemTable = (
  state: IndexerState.t,
  ~effect: Internal.effect,
  ~scope: Internal.chainScope,
) => state->IndexerState.effectState->EffectState.getTable(~effect, ~scope)

let hasEffectOutput = (inMemTable: EffectState.effectCacheInMemTable, key) =>
  switch inMemTable.dict->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(Set(_)) => true
  | Some(Delete(_)) | None => false
  }

// Returns the raw output. The output is itself an option for effects with an
// optional output, so it must never be wrapped in another option here: Some(None)
// is encoded as the nested-option sentinel and would leak to the handler.
let getEffectOutputUnsafe = (
  inMemTable: EffectState.effectCacheInMemTable,
  key,
): Internal.effectOutput =>
  switch inMemTable.dict->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(Set({entity: output})) => output
  | Some(Delete(_)) | None => %raw(`undefined`)
  }

// Records a handler output. Persisted on the next write only when shouldCache;
// otherwise kept in memory (re-run on a later miss) but never written to the db.
let setEffectOutput = (
  inMemTable: EffectState.effectCacheInMemTable,
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
let initEffectOutputFromDb = (inMemTable: EffectState.effectCacheInMemTable, ~cacheKey, ~output) =>
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
  inMemTable: EffectState.effectCacheInMemTable,
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

let prepareRollbackDiff = async (
  state: IndexerState.t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
  ~progressBlockNumberByChainId,
) => {
  state->IndexerState.beginRollbackDiff(
    ~targetCheckpointId=rollbackTargetCheckpointId,
    ~diffCheckpointId=rollbackDiffCheckpointId,
    ~progressBlockNumberByChainId,
  )
  let persistence = state->IndexerState.persistence
  let committedCheckpointId = state->IndexerState.committedCheckpointId

  let deletedEntities = Dict.make()
  let setEntities = Dict.make()

  let _ = await persistence.allEntities
  ->Array.map(async entityConfig => {
    let entityTable = state->getInMemTable(~entityConfig)

    let (removedIds, restoredEntitiesResult) = await persistence.storage.getRollbackData(
      ~entityConfig,
      ~rollbackTargetCheckpointId,
    )

    removedIds->Array.forEach(entityId => {
      deletedEntities->Utils.Dict.push(entityConfig.name, entityId)
      entityTable->InMemoryTable.Entity.set(
        ~committedCheckpointId,
        Delete({
          entityId,
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
        ~committedCheckpointId,
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

let setBatchDcs = (state: IndexerState.t, ~batch: Batch.t) => {
  let inMemTable = state->getInMemTable(~entityConfig=InternalTable.EnvioAddresses.entityConfig)
  let committedCheckpointId = state->IndexerState.committedCheckpointId

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
            ~committedCheckpointId,
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
