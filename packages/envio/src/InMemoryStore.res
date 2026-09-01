// Entity and effect table primitives over IndexerState's in-memory store. State
// mutations route through IndexerState's domain operations; the write loop and
// capacity/flush coordination live in Writing.

// The scope must match the entity's own: a cross-chain entity has one table on
// the indexer, a per-chain entity one table per ChainState. Taking the scope
// rather than an optional chain id keeps a dummy chain id unrepresentable.
let getInMemTable = (
  state: IndexerState.t,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
): InMemoryTable.Entity.t =>
  switch scope {
  | CrossChain => state->IndexerState.entities
  | Chain(chainId) => state->IndexerState.getChainState(~chainId)->ChainState.entities
  }->EntityTables.get(~entityName=entityConfig.name)

// The scope a given entity's rows live in when reached from a handler running
// on `chainId`.
let entityScope = (entityConfig: Internal.entityConfig, ~chainId): Internal.chainScope =>
  entityConfig.crossChain ? CrossChain : Chain(chainId)

// The chain a row loaded from storage belongs to, taken off the row so what's
// left matches the entity schema the handlers see. A per-chain entity whose row
// carries no chain id would silently land in the wrong partition, so it throws.
let takeRowScope = (
  entity: Internal.entity,
  ~entityConfig: Internal.entityConfig,
): Internal.chainScope =>
  switch entityConfig.table->Table.getChainIdField {
  | None => CrossChain
  | Some(field) =>
    let row = entity->(Utils.magic: Internal.entity => dict<ChainId.t>)
    switch row->Utils.Dict.dangerouslyGetNonOption(field.fieldName) {
    | Some(chainId) =>
      row->Utils.Dict.deleteInPlace(field.fieldName)
      Chain(chainId)
    | None =>
      JsError.throwWithMessage(
        `Rollback row for the per-chain entity "${entityConfig.name}" with id "${entity.id}" is missing its "${field.fieldName}" value.`,
      )
    }
  }

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
  inMemTable.dict->Dict.set(
    cacheKey,
    Set({entityId: cacheKey->EntityId.unsafeOfString, entity: output, checkpointId}),
  )
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
      Set({
        entityId: cacheKey->EntityId.unsafeOfString,
        entity: output,
        checkpointId: Internal.loadedFromDbCheckpointId,
      }),
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
  ~rollbackScope: RollbackScope.t,
  ~rollbackTargetCheckpointId,
  ~rollbackDiffCheckpointId,
  ~progressedChains,
  ~rolledBackAddresses,
) => {
  state->IndexerState.beginRollbackDiff(
    ~targetCheckpointId=rollbackTargetCheckpointId,
    ~diffCheckpointId=rollbackDiffCheckpointId,
    ~scope=rollbackScope,
    ~progressedChains,
    ~rolledBackAddresses,
  )
  let persistence = state->IndexerState.persistence
  let committedCheckpointId = state->IndexerState.committedCheckpointId

  let deletedEntities = Dict.make()
  let setEntities = Dict.make()

  // Rollback data comes from Postgres entity history, which is kept only for
  // Postgres-backed entities. ClickHouse-only entities have no history to
  // restore from, so a reorg leaves them un-reverted in the sink.
  let _ = await persistence.allEntities
  ->Array.filter(entityConfig => entityConfig.storage.postgres)
  ->Array.map(async entityConfig => {
    let (removals, restoredEntities) = await persistence.storage.getRollbackData(
      ~entityConfig,
      ~scope=rollbackScope,
      ~rollbackTargetCheckpointId,
    )

    removals->Array.forEach(({entityId, scope}: Persistence.rollbackRemoval) => {
      deletedEntities->Utils.Dict.push(entityConfig.name, entityId)
      state
      ->getInMemTable(~entityConfig, ~scope)
      ->InMemoryTable.Entity.set(
        ~committedCheckpointId,
        Delete({
          entityId,
          checkpointId: rollbackDiffCheckpointId,
        }),
      )
    })

    restoredEntities->Array.forEach((entity: Internal.entity) => {
      let scope = entity->takeRowScope(~entityConfig)
      setEntities->Utils.Dict.push(entityConfig.name, entity.id)
      state
      ->getInMemTable(~entityConfig, ~scope)
      ->InMemoryTable.Entity.set(
        ~committedCheckpointId,
        Set({
          entityId: entity.id->EntityId.unsafeOfString,
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

// Stages the addresses registered by this batch's events for the write. They're
// drained from each chain's address store rather than carried on the items that
// registered them: the store is where they already live, and it knows which
// ones the database hasn't seen yet.
let setBatchDcs = (state: IndexerState.t, ~batch: Batch.t) => {
  batch.progressedChainsById->Utils.Dict.forEach(progressedChain => {
    let chainId = progressedChain.fetchState.chainId
    let chainState = state->IndexerState.getChainState(~chainId)

    // Most batches register nothing, so the checkpoints are only collected for a
    // chain that has something waiting.
    if chainState->ChainState.hasAddressesToWrite {
      // The store pairs each drained registration with a checkpoint of its own
      // chain, so only this chain's checkpoints go in — and the index it returns
      // points back into these two parallel arrays.
      let checkpointIds = []
      let checkpointBlockNumbers = []
      for idx in 0 to batch.checkpointIds->Array.length - 1 {
        if batch.checkpointChainIds->Array.getUnsafe(idx) === chainId {
          checkpointIds->Array.push(batch.checkpointIds->Array.getUnsafe(idx))
          checkpointBlockNumbers->Array.push(batch.checkpointBlockNumbers->Array.getUnsafe(idx))
        }
      }

      batch.registeredAddresses->Array.pushMany(
        chainState
        ->ChainState.drainAddressesForWrite(
          ~toBlockInclusive=progressedChain.progressBlockNumber,
          ~checkpointBlockNumbers,
        )
        ->Array.map((dc): AddressRows.staged => {
          row: {
            chainId,
            address: dc.address,
            contractId: dc.contractId,
            registrationBlock: dc.registrationBlock,
          },
          checkpointId: checkpointIds->Array.getUnsafe(dc.checkpointIdx),
        }),
      )->ignore
    }
  })
}
