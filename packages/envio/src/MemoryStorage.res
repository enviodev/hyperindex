// A `Persistence.storage` that keeps everything in process memory, including
// entity history and the rollback queries a reorg needs. It backs
// `createTestIndexer` and the scenario suite's in-memory leg, so a test that
// passes here means the same thing it means against Postgres.
//
// Entities are stored decoded — there's no worker boundary to serialize across —
// so loads and history comparisons work on real bigint/BigDecimal values.

type checkpointRow = {
  id: Internal.checkpointId,
  chainId: ChainId.t,
  blockNumber: int,
  blockHash: option<string>,
  eventsProcessed: int,
}

// One entity change, kept the way the Postgres history table keeps it: the row
// as of the change, tagged with the checkpoint that produced it. A DELETE
// carries no entity — only the key it removed.
type historyRow = {
  entityId: EntityId.t,
  scope: Internal.chainScope,
  checkpointId: Internal.checkpointId,
  action: EntityHistory.RowAction.t,
  entity: option<Internal.entity>,
}

type chainRow = {
  id: ChainId.t,
  startBlock: int,
  endBlock: option<int>,
  maxReorgDepth: int,
  mutable progressBlockNumber: int,
  mutable sourceBlockNumber: int,
  mutable numEventsProcessed: float,
  mutable firstEventBlockNumber: option<int>,
  mutable latestFetchedBlockNumber: int,
  mutable timestampCaughtUpToHeadOrEndblock: option<Date.t>,
}

type t = {
  // tableName -> row key -> entity, the current state a load reads.
  entities: dict<dict<Internal.entity>>,
  entityConfigs: dict<Internal.entityConfig>,
  // entityName -> changes in write order.
  history: dict<array<historyRow>>,
  mutable checkpoints: array<checkpointRow>,
  chains: dict<chainRow>,
  cache: dict<Persistence.effectCacheRecord>,
  effectCache: dict<dict<Internal.effectCacheItem>>,
  mutable envioInfo: option<JSON.t>,
  addresses: AddressRows.Table.t,
  mutable isInitialized: bool,
}

let make = (): t => {
  entities: Dict.make(),
  entityConfigs: Dict.make(),
  history: Dict.make(),
  checkpoints: [],
  chains: Dict.make(),
  cache: Dict.make(),
  effectCache: Dict.make(),
  envioInfo: None,
  addresses: AddressRows.Table.make(),
  isInitialized: false,
}

// Rows of a per-chain entity are keyed per (chain, id): the same id exists
// independently on every chain.
let rowKey = (~scope: Internal.chainScope, ~entityId: EntityId.t) =>
  switch scope {
  | CrossChain => entityId->EntityId.toKey
  | Chain(chainId) => `${chainId->ChainId.toString}|${entityId->EntityId.toKey}`
  }

let historyKey = (~scope: Internal.chainScope, ~entityId: EntityId.t) => rowKey(~scope, ~entityId)

let readChainId = (entity: Internal.entity, ~field: Table.field): option<ChainId.t> =>
  entity
  ->(Utils.magic: Internal.entity => dict<ChainId.t>)
  ->Utils.Dict.dangerouslyGetNonOption(field.fieldName)

// The store owns its entities. Copy on the boundary with user code — both when
// handing one out and when taking one in — so a user mutating a returned
// entity, or an object they passed to `set`, can't corrupt the store. The copy
// is shallow (matching InMemoryTable): scalar fields are immutable, but
// array-valued fields still share the backing array.
let copyEntity = (entity: Internal.entity): Internal.entity =>
  entity
  ->(Utils.magic: Internal.entity => dict<unknown>)
  ->Utils.Dict.shallowCopy
  ->(Utils.magic: dict<unknown> => Internal.entity)

let getEntityDict = (state: t, ~name) =>
  switch state.entities->Dict.get(name) {
  | Some(dict) => dict
  | None =>
    let dict = Dict.make()
    state.entities->Dict.set(name, dict)
    dict
  }

let getHistory = (state: t, ~name) =>
  switch state.history->Dict.get(name) {
  | Some(rows) => rows
  | None =>
    let rows = []
    state.history->Dict.set(name, rows)
    rows
  }

let registerEntities = (state: t, ~entities: array<Internal.entityConfig>) =>
  entities->Array.forEach(entityConfig => {
    state.entityConfigs->Dict.set(entityConfig.name, entityConfig)
    state.entityConfigs->Dict.set(entityConfig.table.tableName, entityConfig)
    let _ = state->getEntityDict(~name=entityConfig.name)
  })

// Seeds the config's contract addresses, mirroring what PgStorage.initialize
// writes into `envio_addresses`.
let seedConfigAddresses = (
  state: t,
  ~chainConfigs: array<Config.chain>,
  ~contractMapping,
  ~ecosystem,
) => {
  // Initialize starts from an empty schema — the Postgres DDL drops and
  // recreates one — so a re-initialize must not stack a second copy of the
  // config's addresses on what a previous one left behind.
  state.addresses->AddressRows.Table.clear
  state.addresses->ChainState.seedConfigAddresses(~chainConfigs, ~ecosystem, ~contractMapping)
}

let addressRowsByChain = (state: t) => state.addresses->AddressRows.Table.groupByChain

let toInitialChainStates = (state: t): array<Persistence.initialChainState> => {
  let addressesByChain = state->addressRowsByChain
  state.chains
  ->Dict.valuesToArray
  ->Array.map((chain): Persistence.initialChainState => {
    id: chain.id,
    startBlock: chain.startBlock,
    endBlock: chain.endBlock,
    maxReorgDepth: chain.maxReorgDepth,
    progressBlockNumber: chain.progressBlockNumber,
    numEventsProcessed: chain.numEventsProcessed,
    firstEventBlockNumber: chain.firstEventBlockNumber,
    timestampCaughtUpToHeadOrEndblock: chain.timestampCaughtUpToHeadOrEndblock,
    addressRows: addressesByChain
    ->Utils.Dict.dangerouslyGetNonOption(chain.id->ChainId.toString)
    ->Option.getOr(AddressRows.emptySeedRows()),
    sourceBlockNumber: chain.sourceBlockNumber,
  })
}

let committedCheckpointId = (state: t) =>
  state.checkpoints->Array.reduce(InternalTable.Checkpoints.initialCheckpointId, (max, cp) =>
    cp.id > max ? cp.id : max
  )

// Mirrors `makeGetReorgCheckpointsQuery`: the hashed checkpoints still inside
// a reorg-capable chain's threshold, which is what reorg detection resumes from.
let reorgCheckpoints = (state: t): array<Internal.reorgCheckpoint> =>
  state.checkpoints->Array.filterMap(cp =>
    switch (cp.blockHash, state.chains->Dict.get(cp.chainId->ChainId.toString)) {
    | (Some(blockHash), Some(chain)) =>
      let safeBlock = chain.sourceBlockNumber - chain.maxReorgDepth
      if (
        chain.maxReorgDepth > 0 &&
        chain.progressBlockNumber > safeBlock &&
        cp.blockNumber >= safeBlock
      ) {
        Some({
          Internal.checkpointId: cp.id,
          chainId: cp.chainId,
          blockNumber: cp.blockNumber,
          blockHash,
        })
      } else {
        None
      }
    | _ => None
    }
  )

let toInitialState = (state: t, ~cleanRun, ~contractMapping): Persistence.initialState => {
  cleanRun,
  contractMapping,
  envioInfo: state.envioInfo,
  cache: state.cache,
  chains: state->toInitialChainStates,
  checkpointId: state->committedCheckpointId,
  reorgCheckpoints: state->reorgCheckpoints,
}

let handleLoad = (state: t, ~tableName: string, ~filter: EntityFilter.t): array<
  Internal.entity,
> => {
  // Effect caches (`envio_effect_<name>`) are loaded through the same call, and
  // they have no entity config — they're served from the cache `writeBatch`
  // filled, so a resumed indexer reuses cached outputs instead of recomputing
  // them the way Postgres would.
  switch state.entityConfigs->Dict.get(tableName) {
  | None =>
    switch state.effectCache->Dict.get(tableName) {
    | None => []
    | Some(cacheDict) =>
      cacheDict
      ->Dict.valuesToArray
      ->Array.filter(item =>
        filter->EntityFilter.matches(
          ~entity=item->(Utils.magic: Internal.effectCacheItem => dict<EntityFilter.FieldValue.t>),
        )
      )
      ->(Utils.magic: array<Internal.effectCacheItem> => array<Internal.entity>)
    }
  | Some(entityConfig) =>
    let entityDict = state.entities->Dict.get(entityConfig.name)->Option.getOr(Dict.make())
    let matched =
      entityDict
      ->Dict.valuesToArray
      ->Array.filter(entity => {
        // The store holds decoded entities and the filter carries decoded values,
        // so compare directly (same approach as InMemoryTable) — no JSON round-trip.
        let entityAsDict = entity->(Utils.magic: Internal.entity => dict<EntityFilter.FieldValue.t>)
        filter->EntityFilter.matches(~entity=entityAsDict)
      })
    // The chain is already fixed by the scope the load ran for, so the loaded
    // entity is handed back in the shape the handlers see.
    switch entityConfig.table->Table.getChainIdField {
    | None => matched
    | Some(field) =>
      matched->Array.map(entity => {
        let copy = entity->(Utils.magic: Internal.entity => dict<unknown>)->Utils.Dict.shallowCopy
        copy->Utils.Dict.deleteInPlace(field.fieldName)
        copy->(Utils.magic: dict<unknown> => Internal.entity)
      })
    }
  }
}

// Postgres backfills a history row for an entity that predates history being
// kept, so a rollback can restore it. Same here: the current row is recorded as
// a SET at the initial checkpoint the first time the entity gains history.
let backfillHistory = (
  state: t,
  ~entityConfig: Internal.entityConfig,
  ~scope,
  ~entityId,
  ~rows: array<historyRow>,
) => {
  let key = historyKey(~scope, ~entityId)
  if !(rows->Array.some(row => historyKey(~scope=row.scope, ~entityId=row.entityId) === key)) {
    switch state.entities
    ->Dict.get(entityConfig.name)
    ->Option.flatMap(dict => dict->Dict.get(rowKey(~scope, ~entityId))) {
    | Some(entity) =>
      rows
      ->Array.push({
        entityId,
        scope,
        checkpointId: InternalTable.Checkpoints.initialCheckpointId,
        action: EntityHistory.RowAction.SET,
        entity: Some(entity),
      })
      ->ignore
    | None => ()
    }
  }
}

let applyRollback = (state: t, ~targetCheckpointId, ~rolledBackAddresses) => {
  state.checkpoints = state.checkpoints->Array.filter(cp => cp.id <= targetCheckpointId)
  // Addresses are removed by primary key, exactly like the Postgres delete.
  rolledBackAddresses->Array.forEach(key => state.addresses->AddressRows.Table.delete(key))
  state.history
  ->Dict.toArray
  ->Array.forEach(((name, rows)) =>
    state.history->Dict.set(name, rows->Array.filter(row => row.checkpointId <= targetCheckpointId))
  )
}

let writeBatch = (
  state: t,
  ~batch: Batch.t,
  ~rollback: option<Persistence.rollback>,
  ~isInReorgThreshold,
  ~config: Config.t,
  ~updatedEntities: array<Persistence.updatedEntity>,
  ~registeredAddresses: array<AddressRows.staged>,
  ~updatedEffectsCache: array<Persistence.updatedEffectCache>,
  ~chainMetaData: option<dict<InternalTable.Chains.metaFields>>,
) => {
  let shouldSaveHistory = config->Config.shouldSaveHistory(~isInReorgThreshold)

  // Rollback first, exactly like the Postgres transaction: the batch being
  // written is the reprocessed one, so its rows must land on the reverted state.
  switch rollback {
  | Some({targetCheckpointId, rolledBackAddresses}) =>
    state->applyRollback(~targetCheckpointId, ~rolledBackAddresses)
  | None => ()
  }

  registeredAddresses->Array.forEach(({row}) => state.addresses->AddressRows.Table.insert(row))

  // The rollback diff restates what the reverted state already is, so it is not
  // a change history should record — and an id it touches needs no backfill
  // either, because the diff already carries its reverted value. Postgres draws
  // the same line, keyed on the diff's checkpoint id.
  let diffCheckpointId = rollback->Option.map(({diffCheckpointId}) => diffCheckpointId)
  let isDiff = (change: Change.t<Internal.entity>) =>
    switch diffCheckpointId {
    | Some(diffCheckpointId) => change->Change.getCheckpointId === diffCheckpointId
    | None => false
    }

  updatedEntities->Array.forEach(({entityConfig, scope, changes}: Persistence.updatedEntity) => {
    let entityDict = state->getEntityDict(~name=entityConfig.name)
    let historyRows = state->getHistory(~name=entityConfig.name)
    // The scope is what makes a per-chain row identifiable, so it's stamped
    // onto the stored entity the same way the Postgres write path does.
    let chainIdField = entityConfig.table->Table.getChainIdField

    let idsWithDiff = Utils.Set.make()
    changes->Array.forEach(change =>
      if isDiff(change) {
        idsWithDiff->Utils.Set.add(change->Change.getEntityId->EntityId.toKey)->ignore
      }
    )

    changes->Array.forEach(change => {
      let entityId = change->Change.getEntityId
      let shouldSaveChangeHistory = shouldSaveHistory && !isDiff(change)
      if shouldSaveHistory && !(idsWithDiff->Utils.Set.has(entityId->EntityId.toKey)) {
        state->backfillHistory(~entityConfig, ~scope, ~entityId, ~rows=historyRows)
      }
      switch change {
      | Set({entity, checkpointId}) =>
        let storedEntity = switch (chainIdField, scope->Internal.chainScopeChainId) {
        | (Some(field), Some(chainId)) =>
          entity->Internal.stampChainId(~fieldName=field.fieldName, ~chainId)
        | _ => entity
        }
        entityDict->Dict.set(rowKey(~scope, ~entityId), storedEntity)
        if shouldSaveChangeHistory {
          historyRows
          ->Array.push({
            entityId,
            scope,
            checkpointId,
            action: EntityHistory.RowAction.SET,
            entity: Some(storedEntity),
          })
          ->ignore
        }
      | Delete({checkpointId}) =>
        entityDict->Utils.Dict.deleteInPlace(rowKey(~scope, ~entityId))
        if shouldSaveChangeHistory {
          historyRows
          ->Array.push({
            entityId,
            scope,
            checkpointId,
            action: EntityHistory.RowAction.DELETE,
            entity: None,
          })
          ->ignore
        }
      }
    })
  })

  batch.progressedChainsById
  ->Dict.valuesToArray
  ->Array.forEach(chainAfterBatch => {
    let key = chainAfterBatch.fetchState.chainId->ChainId.toString
    switch state.chains->Dict.get(key) {
    | Some(chain) =>
      chain.progressBlockNumber = chainAfterBatch.progressBlockNumber
      chain.sourceBlockNumber = chainAfterBatch.sourceBlockNumber
      chain.numEventsProcessed = chainAfterBatch.totalEventsProcessed
    | None => ()
    }
  })

  switch chainMetaData {
  | Some(chainsData) =>
    chainsData
    ->Dict.toArray
    ->Array.forEach(((key, meta)) =>
      switch state.chains->Dict.get(key) {
      | Some(chain) =>
        chain.firstEventBlockNumber = meta.firstEventBlockNumber->Null.toOption
        chain.latestFetchedBlockNumber = meta.latestFetchedBlockNumber
        chain.timestampCaughtUpToHeadOrEndblock =
          meta.timestampCaughtUpToHeadOrEndblock->Null.toOption
      | None => ()
      }
    )
  | None => ()
  }

  if shouldSaveHistory {
    for i in 0 to batch.checkpointIds->Array.length - 1 {
      state.checkpoints
      ->Array.push({
        id: batch.checkpointIds->Array.getUnsafe(i),
        chainId: batch.checkpointChainIds->Array.getUnsafe(i),
        blockNumber: batch.checkpointBlockNumbers->Array.getUnsafe(i),
        blockHash: batch.checkpointBlockHashes->Array.getUnsafe(i)->Null.toOption,
        eventsProcessed: batch.checkpointEventsProcessed->Array.getUnsafe(i),
      })
      ->ignore
    }
  }

  updatedEffectsCache->Array.forEach(({table, items}: Persistence.updatedEffectCache) => {
    let cacheDict = switch state.effectCache->Dict.get(table.tableName) {
    | Some(dict) => dict
    | None =>
      let dict = Dict.make()
      state.effectCache->Dict.set(table.tableName, dict)
      dict
    }
    items->Array.forEach(item => cacheDict->Dict.set(item.id, item))
    switch state.cache->Dict.get(table.tableName) {
    | Some(record) => record.count = cacheDict->Dict.keysToArray->Array.length
    | None => ()
    }
  })
}

// The latest history row at or before the target, for keys changed after it —
// the memory equivalent of `makeGetRollbackPreTargetRowsQuery`.
let getRollbackData = (
  state: t,
  ~entityConfig: Internal.entityConfig,
  ~rollbackTargetCheckpointId,
) => {
  let rows = state.history->Dict.get(entityConfig.name)->Option.getOr([])

  let changedKeys = Dict.make()
  rows->Array.forEach(row =>
    if row.checkpointId > rollbackTargetCheckpointId {
      changedKeys->Dict.set(historyKey(~scope=row.scope, ~entityId=row.entityId), row)
    }
  )

  let removals = []
  let restored = []

  changedKeys
  ->Dict.toArray
  ->Array.forEach(((key, changedRow)) => {
    let preTarget = rows->Array.reduce(None, (latest, row) =>
      if (
        historyKey(~scope=row.scope, ~entityId=row.entityId) === key &&
          row.checkpointId <= rollbackTargetCheckpointId
      ) {
        switch latest {
        | Some(current: historyRow) if current.checkpointId >= row.checkpointId => latest
        | _ => Some(row)
        }
      } else {
        latest
      }
    )
    switch preTarget {
    // Nothing before the target: the entity only ever existed after it.
    | None =>
      removals
      ->Array.push({Persistence.entityId: changedRow.entityId, scope: changedRow.scope})
      ->ignore
    | Some({action: DELETE, entityId, scope}) =>
      removals->Array.push({Persistence.entityId, scope})->ignore
    | Some({action: SET, entity: Some(entity)}) => restored->Array.push(entity)->ignore
    | Some({action: SET, entity: None}) => ()
    }
  })

  (removals, restored)
}

type progressDiff = {
  chainId: ChainId.t,
  mutable eventsProcessed: int,
  mutable newProgressBlockNumber: int,
}

let getRollbackProgressDiff = (state: t, ~rollbackTargetCheckpointId) => {
  let byChain = Dict.make()
  state.checkpoints->Array.forEach(cp =>
    if cp.id > rollbackTargetCheckpointId {
      let key = cp.chainId->ChainId.toString
      switch byChain->Dict.get(key) {
      | Some(acc) =>
        acc.eventsProcessed = acc.eventsProcessed + cp.eventsProcessed
        acc.newProgressBlockNumber = Math.Int.min(acc.newProgressBlockNumber, cp.blockNumber - 1)
      | None =>
        byChain->Dict.set(
          key,
          {
            chainId: cp.chainId,
            eventsProcessed: cp.eventsProcessed,
            newProgressBlockNumber: cp.blockNumber - 1,
          },
        )
      }
    }
  )
  byChain
  ->Dict.valuesToArray
  ->Array.map(acc =>
    {
      "chain_id": acc.chainId,
      "events_processed_diff": acc.eventsProcessed->Int.toString,
      "new_progress_block_number": acc.newProgressBlockNumber,
    }
  )
}

let toStorage = (state: t, ~config: Config.t): Persistence.storage => {
  name: "memory",
  isInitialized: async () => state.isInitialized,
  initialize: async (~chainConfigs=[], ~entities=[], ~enums as _=[], ~contractMapping, ~envioInfo) => {
    state->registerEntities(~entities)
    state->seedConfigAddresses(~chainConfigs, ~contractMapping, ~ecosystem=config.ecosystem.name)
    chainConfigs->Array.forEach(chainConfig =>
      state.chains->Dict.set(
        chainConfig.id->ChainId.toString,
        {
          id: chainConfig.id,
          startBlock: chainConfig.startBlock,
          endBlock: chainConfig.endBlock,
          maxReorgDepth: chainConfig.maxReorgDepth,
          progressBlockNumber: -1,
          sourceBlockNumber: 0,
          numEventsProcessed: 0.,
          firstEventBlockNumber: None,
          latestFetchedBlockNumber: 0,
          timestampCaughtUpToHeadOrEndblock: None,
        },
      )
    )
    state.envioInfo = Some(envioInfo)
    state.isInitialized = true
    state->toInitialState(~cleanRun=true, ~contractMapping)
  },
  resumeInitialState: async () =>
    state->toInitialState(~cleanRun=false, ~contractMapping=config.contractMapping),
  loadOrThrow: async (~filter, ~table: Table.table) =>
    state
    ->handleLoad(~tableName=table.tableName, ~filter)
    ->(Utils.magic: array<Internal.entity> => array<unknown>),
  // Nothing to index, and the store is always queryable.
  ensureQueryIndexes: async (~table as _, ~filters as _) => (),
  ensureSchemaIndexes: async (~entities as _) => (),
  finalizeBackfill: async (~entities as _, ~chainIds, ~readyAt) =>
    chainIds->Array.forEach(chainId =>
      switch state.chains->Dict.get(chainId->ChainId.toString) {
      | Some(chain) => chain.timestampCaughtUpToHeadOrEndblock = Some(readyAt)
      | None => ()
      }
    ),
  dumpEffectCache: async () => (),
  reset: async () => {
    let clear = Utils.Dict.clearInPlace
    state.entities->clear
    state.history->clear
    state.chains->clear
    state.effectCache->clear
    state.cache->clear
    state.checkpoints = []
    state.addresses->AddressRows.Table.clear
    state.envioInfo = None
    state.isInitialized = false
  },
  setChainMeta: async chainsData => {
    chainsData
    ->Dict.toArray
    ->Array.forEach(((key, meta)) =>
      switch state.chains->Dict.get(key) {
      | Some(chain) =>
        chain.firstEventBlockNumber = meta.firstEventBlockNumber->Null.toOption
        chain.latestFetchedBlockNumber = meta.latestFetchedBlockNumber
        chain.timestampCaughtUpToHeadOrEndblock =
          meta.timestampCaughtUpToHeadOrEndblock->Null.toOption
      | None => ()
      }
    )
    %raw(`undefined`)
  },
  pruneStaleCheckpoints: async (~safeCheckpointId) => {
    state.checkpoints = state.checkpoints->Array.filter(cp => cp.id >= safeCheckpointId)
  },
  pruneStaleEntityHistory: async (
    ~entityName,
    ~entityIndex as _,
    ~chainIdColumn as _,
    ~safeCheckpointId,
  ) => {
    switch state.history->Dict.get(entityName) {
    | None => ()
    | Some(rows) =>
      // Keep the newest row below the safe point per key: it's what a rollback
      // to the safe checkpoint restores to.
      let newestBelow = Dict.make()
      rows->Array.forEach(row =>
        if row.checkpointId < safeCheckpointId {
          let key = historyKey(~scope=row.scope, ~entityId=row.entityId)
          switch newestBelow->Dict.get(key) {
          | Some(current: historyRow) if current.checkpointId >= row.checkpointId => ()
          | _ => newestBelow->Dict.set(key, row)
          }
        }
      )
      state.history->Dict.set(
        entityName,
        rows->Array.filter(row => {
          let key = historyKey(~scope=row.scope, ~entityId=row.entityId)
          row.checkpointId >= safeCheckpointId ||
            switch newestBelow->Dict.get(key) {
            | Some(kept) => kept === row
            | None => false
            }
        }),
      )
    }
  },
  getRollbackTargetCheckpoint: async (~reorgChainId, ~lastKnownValidBlockNumber) =>
    state.checkpoints->Array.reduce(None, (target, cp) =>
      if cp.chainId == reorgChainId && cp.blockNumber <= lastKnownValidBlockNumber {
        switch target {
        | Some(current) if current >= cp.id => target
        | _ => Some(cp.id)
        }
      } else {
        target
      }
    ),
  getRollbackProgressDiff: async (~rollbackTargetCheckpointId) =>
    state->getRollbackProgressDiff(~rollbackTargetCheckpointId),
  getRollbackData: async (~entityConfig, ~rollbackTargetCheckpointId) =>
    state->getRollbackData(~entityConfig, ~rollbackTargetCheckpointId),
  writeBatch: async (
    ~batch,
    ~rollback,
    ~isInReorgThreshold,
    ~config as _,
    ~allEntities as _,
    ~updatedEffectsCache,
    ~updatedEntities,
    ~registeredAddresses,
    ~chainMetaData,
    ~onWrite as _,
  ) =>
    state->writeBatch(
      ~batch,
      ~rollback,
      ~isInReorgThreshold,
      ~config,
      ~updatedEntities,
      ~registeredAddresses,
      ~updatedEffectsCache,
      ~chainMetaData,
    ),
  close: async () => (),
}

// Read helpers for tests. They mirror what the Postgres-backed equivalents
// return, so one assertion can run against either backend.
let currentRows = (state: t, ~entityConfig: Internal.entityConfig): array<Internal.entity> =>
  state.entities->Dict.get(entityConfig.name)->Option.getOr(Dict.make())->Dict.valuesToArray

let historyChanges = (state: t, ~entityConfig: Internal.entityConfig): array<
  Change.t<Internal.entity>,
> =>
  state.history
  ->Dict.get(entityConfig.name)
  ->Option.getOr([])
  ->Array.map(row =>
    switch row.action {
    | SET =>
      Change.Set({
        entityId: row.entityId,
        checkpointId: row.checkpointId,
        entity: row.entity->Option.getOr(%raw(`{}`)),
      })
    | DELETE => Change.Delete({entityId: row.entityId, checkpointId: row.checkpointId})
    }
  )
  ->Array.toSorted((a, b) =>
    switch String.compare(
      a->Change.getEntityId->EntityId.toKey,
      b->Change.getEntityId->EntityId.toKey,
    ) {
    | 0. =>
      Float.compare(
        a->Change.getCheckpointId->BigInt.toFloat,
        b->Change.getCheckpointId->BigInt.toFloat,
      )
    | order => order
    }
  )

let checkpointRows = (state: t): array<InternalTable.Checkpoints.t> =>
  state.checkpoints->Array.map(cp => {
    InternalTable.Checkpoints.id: cp.id,
    chainId: cp.chainId,
    blockNumber: cp.blockNumber,
    blockHash: cp.blockHash->Null.fromOption,
    eventsProcessed: cp.eventsProcessed,
  })

let effectCacheRows = (state: t, ~tableName): array<{
  "id": string,
  "output": JSON.t,
}> =>
  state.effectCache
  ->Dict.get(tableName)
  ->Option.getOr(Dict.make())
  ->Dict.valuesToArray
  ->Array.map(item =>
    {
      "id": item.id,
      "output": item.output->(Utils.magic: Internal.effectOutput => JSON.t),
    }
  )
