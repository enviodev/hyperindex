// Entity and effect table primitives over IndexerState's in-memory store. State
// mutations route through IndexerState's domain operations; the write loop and
// capacity/flush coordination live in Writing.

// Cross-chain entities are shared across chains; per-chain entities live on
// ChainState so the same id on different chains stays distinct.
let getInMemTable = (
  state: IndexerState.t,
  ~entityConfig: Internal.entityConfig,
  ~chainId: int,
): InMemoryTable.Entity.t =>
  if entityConfig.crossChain {
    state->IndexerState.entities->EntityTables.get(~entityName=entityConfig.name)
  } else {
    state
    ->IndexerState.getChainState(~chain=ChainMap.Chain.makeUnsafe(~chainId))
    ->ChainState.entities
    ->EntityTables.get(~entityName=entityConfig.name)
  }

// Every in-memory entity table, tagged with the chain it belongs to: cross-chain
// tables once (chain None), per-chain tables once per chain. Used by the
// store-wide passes (size, drop, flush) that must fan over all chains.
let eachEntityTable = (state: IndexerState.t): array<(
  option<int>,
  Internal.entityConfig,
  InMemoryTable.Entity.t,
)> => {
  let result = []
  state
  ->IndexerState.allEntities
  ->Array.forEach(entityConfig => {
    if entityConfig.crossChain {
      result
      ->Array.push((
        None,
        entityConfig,
        state->IndexerState.entities->EntityTables.get(~entityName=entityConfig.name),
      ))
      ->ignore
    } else {
      state
      ->IndexerState.chainStates
      ->Utils.Dict.forEach(cs => {
        result
        ->Array.push((
          Some((cs->ChainState.chainConfig).id),
          entityConfig,
          cs->ChainState.entities->EntityTables.get(~entityName=entityConfig.name),
        ))
        ->ignore
      })
    }
  })
  result
}

let getEffectInMemTable = (state: IndexerState.t, ~effect: Internal.effect) => {
  let key = effect.name
  let effects = state->IndexerState.effects
  switch effects->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(table) => table
  | None =>
    let table: IndexerState.effectCacheInMemTable = {
      idsToStore: [],
      dict: Dict.make(),
      changesCount: 0.,
      invalidationsCount: 0,
      effect,
    }
    effects->Dict.set(key, table)
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

  // Per-chain entities route per chain (removed rows carry the chain id,
  // restored rows carry it in the chainId column); cross-chain ones ignore it.
  let _ = await persistence.allEntities
  ->Array.map(async entityConfig => {
    let (removedIdsResult, restoredEntitiesResult) = await persistence.storage.getRollbackData(
      ~entityConfig,
      ~rollbackTargetCheckpointId,
    )

    removedIdsResult->Array.forEach(data => {
      deletedEntities->Utils.Dict.push(entityConfig.name, data["id"])
      let chainId = entityConfig.crossChain ? 0 : data["chainId"]->Option.getOr(0)
      state
      ->getInMemTable(~entityConfig, ~chainId)
      ->InMemoryTable.Entity.set(
        ~committedCheckpointId,
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
      let chainId = entityConfig.crossChain
        ? 0
        : (entity->(Utils.magic: Internal.entity => {"chainId": int}))["chainId"]
      state
      ->getInMemTable(~entityConfig, ~chainId)
      ->InMemoryTable.Entity.set(
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
  let committedCheckpointId = state->IndexerState.committedCheckpointId

  let itemIdx = ref(0)

  for checkpoint in 0 to batch.checkpointIds->Array.length - 1 {
    let checkpointId = batch.checkpointIds->Array.getUnsafe(checkpoint)
    let chainId = batch.checkpointChainIds->Array.getUnsafe(checkpoint)
    let checkpointEventsProcessed = batch.checkpointEventsProcessed->Array.getUnsafe(checkpoint)

    let inMemTable =
      state->getInMemTable(~entityConfig=InternalTable.EnvioAddresses.entityConfig, ~chainId)

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
