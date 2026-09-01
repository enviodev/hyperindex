type evmChainConfig = {
  startBlock?: int,
  endBlock?: int,
  simulate?: array<Envio.evmSimulateItem>,
}

type fuelChainConfig = {
  startBlock?: int,
  endBlock?: int,
  simulate?: array<Envio.fuelSimulateItem>,
}

type svmChainConfig = {
  startBlock?: int,
  endBlock?: int,
  simulate?: array<Envio.svmSimulateItem>,
}

// Internal type used for block range validation and state management
type chainConfig = {
  startBlock: int,
  endBlock: option<int>,
}

type processResult = {changes: array<unknown>}

type t<'processConfig> = {process: 'processConfig => promise<processResult>}

type entityChange = {
  sets: array<unknown>,
  deleted: array<EntityId.t>,
}

type testIndexerState = {
  mutable processInProgress: bool,
  progressBlockByChain: dict<int>,
  // Store decoded entities (not JSON) for proper comparison operations
  entities: dict<dict<Internal.entity>>,
  entityConfigs: dict<Internal.entityConfig>,
  addresses: AddressRows.Table.t,
  contractMapping: ContractMapping.t,
  mutable processChanges: array<unknown>,
}

let addressRowsByChain = (state: testIndexerState) =>
  state.addresses->AddressRows.Table.groupByChain

let renderRows = (rows: array<AddressRows.row>, ~config: Config.t) =>
  rows->AddressRows.render(
    ~ecosystem=(config.ecosystem.name :> string),
    ~shouldChecksum=!config.lowercaseAddresses,
  )

// Rows of a per-chain entity are keyed per (chain, id): the same id exists
// independently on every chain.
let rowKey = (~scope: Internal.chainScope, ~entityId: EntityId.t) =>
  switch scope {
  | CrossChain => entityId->EntityId.toKey
  | Chain(chainId) => `${chainId->ChainId.toString}|${entityId->EntityId.toKey}`
  }

let readChainId = (entity: Internal.entity, ~field: Table.field): option<ChainId.t> =>
  entity
  ->(Utils.magic: Internal.entity => dict<ChainId.t>)
  ->Utils.Dict.dangerouslyGetNonOption(field.fieldName)

let handleLoad = (state: testIndexerState, ~tableName: string, ~filter: EntityFilter.t): array<
  Internal.entity,
> => {
  // Loads for non-entity tables (e.g. effect caches `envio_effect_<name>`) reach
  // here too. TestIndexer never persists those, so there's nothing to return —
  // an empty result makes the effect recompute instead of crashing on a missing
  // entityConfig.
  switch state.entityConfigs->Dict.get(tableName) {
  | None => []
  | Some(entityConfig) =>
    let entityDict = state.entities->Dict.get(tableName)->Option.getOr(Dict.make())
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

let handleWriteBatch = (
  state: testIndexerState,
  ~config: Config.t,
  ~updatedEntities: array<Persistence.updatedEntity>,
  ~registeredAddresses: array<AddressRows.staged>,
  ~checkpointIds: array<bigint>,
  ~checkpointChainIds: array<ChainId.t>,
  ~checkpointBlockNumbers: array<int>,
  ~checkpointEventsProcessed: array<int>,
): unit => {
  // Group entity changes by checkpointId
  // checkpointId -> entityName -> entityChange
  let changesByCheckpoint: dict<dict<entityChange>> = Dict.make()

  // checkpointId -> the addresses that checkpoint registered, rendered for the
  // change log. Rendering is the Rust codec's job, so the rows keep their keys
  // right up to here.
  let addressesByCheckpoint: dict<array<{"address": Address.t, "contract": string}>> = Dict.make()
  let rendered = registeredAddresses->Array.map(({row}) => row)->renderRows(~config)
  registeredAddresses->Array.forEachWithIndex(({row, checkpointId}, idx) => {
    state.addresses->AddressRows.Table.insert(row)
    addressesByCheckpoint->Utils.Dict.push(
      checkpointId->BigInt.toString,
      {
        "address": rendered->Array.getUnsafe(idx),
        "contract": state.contractMapping->ContractMapping.nameOfOrThrow(row.contractId),
      },
    )
  })

  updatedEntities->Array.forEach(({entityConfig, scope, changes}: Persistence.updatedEntity) => {
    let entityName = entityConfig.name
    // The scope is what makes a per-chain row identifiable, so it's stamped
    // onto the stored entity the same way the Postgres write path does.
    let chainIdField = entityConfig.table->Table.getChainIdField
    let entityDict = switch state.entities->Dict.get(entityName) {
    | Some(dict) => dict
    | None =>
      let dict = Dict.make()
      state.entities->Dict.set(entityName, dict)
      dict
    }

    let entityChangeFor = checkpointId => {
      let checkpointKey = checkpointId->BigInt.toString
      let entityChanges = switch changesByCheckpoint->Dict.get(checkpointKey) {
      | Some(changes) => changes
      | None =>
        let changes = Dict.make()
        changesByCheckpoint->Dict.set(checkpointKey, changes)
        changes
      }
      switch entityChanges->Dict.get(entityName) {
      | Some(change) => change
      | None =>
        let change = {sets: [], deleted: []}
        entityChanges->Dict.set(entityName, change)
        change
      }
    }

    let processChange = (change: Change.t<Internal.entity>) => {
      switch change {
      | Set({entityId, entity, checkpointId}) =>
        // The store keeps decoded entities so load comparisons (bigint /
        // BigDecimal) work on real values. Ids are keyed by their string form
        // since they may be string/int/bigint.
        let storedEntity = switch (chainIdField, scope->Internal.chainScopeChainId) {
        | (Some(field), Some(chainId)) =>
          entity->Internal.stampChainId(~fieldName=field.fieldName, ~chainId)
        | _ => entity
        }
        entityDict->Dict.set(rowKey(~scope, ~entityId), storedEntity)
        // The change already carries the checkpoint's chainId, so the entity
        // inside it stays unstamped.
        entityChangeFor(checkpointId).sets->Array.push(entity->Utils.magic)->ignore
      | Delete({entityId, checkpointId}) =>
        Dict.delete(entityDict->Obj.magic, rowKey(~scope, ~entityId))
        entityChangeFor(checkpointId).deleted->Array.push(entityId)->ignore
      }
    }

    // Every change carries its own checkpointId and each (id, checkpointId)
    // appears at most once in the batch, so record them all into their buckets.
    changes->Array.forEach(processChange)
  })

  // Build combined checkpoint + entity changes objects
  for i in 0 to checkpointIds->Array.length - 1 {
    let checkpointId = checkpointIds->Array.getUnsafe(i)
    let change: dict<unknown> = Dict.make()

    // Update progress tracking from checkpoint data
    state.progressBlockByChain->Dict.set(
      checkpointChainIds->Array.getUnsafe(i)->ChainId.toString,
      checkpointBlockNumbers->Array.getUnsafe(i),
    )

    // Add checkpoint metadata
    change->Dict.set("block", checkpointBlockNumbers->Array.getUnsafe(i)->Utils.magic)
    change->Dict.set("chainId", checkpointChainIds->Array.getUnsafe(i)->Utils.magic)
    change->Dict.set("eventsProcessed", checkpointEventsProcessed->Array.getUnsafe(i)->Utils.magic)

    // Add entity changes for this checkpoint
    let checkpointKey = checkpointId->BigInt.toString
    switch addressesByCheckpoint->Utils.Dict.dangerouslyGetNonOption(checkpointKey) {
    | Some(rendered) =>
      let addressesObj: dict<unknown> = Dict.make()
      addressesObj->Dict.set(
        "sets",
        rendered->(Utils.magic: array<{"address": Address.t, "contract": string}> => unknown),
      )
      change->Dict.set("addresses", addressesObj->(Utils.magic: dict<unknown> => unknown))
    | None => ()
    }
    switch changesByCheckpoint->Dict.get(checkpointKey) {
    | Some(entityChanges) =>
      entityChanges
      ->Dict.toArray
      ->Array.forEach(((entityName, {sets, deleted})) => {
        let entityObj: dict<unknown> = Dict.make()
        if sets->Array.length > 0 {
          entityObj->Dict.set("sets", sets->(Utils.magic: array<unknown> => unknown))
        }
        if deleted->Array.length > 0 {
          entityObj->Dict.set("deleted", deleted->(Utils.magic: array<EntityId.t> => unknown))
        }
        // Match the capitalized entity accessor the generated change types expose.
        change->Dict.set(
          entityName->Utils.String.capitalize,
          entityObj->(Utils.magic: dict<unknown> => unknown),
        )
      })
    | None => ()
    }

    state.processChanges
    ->Array.push(change->(Utils.magic: dict<unknown> => unknown))
    ->ignore
  }
}

let makeInitialState = (
  ~config: Config.t,
  ~processConfigChains: dict<chainConfig>,
  ~addressRowsByChain: dict<AddressRows.seedRows>,
  ~contractMapping: ContractMapping.t,
): Persistence.initialState => {
  let chainKeys = processConfigChains->Dict.keysToArray
  let chains = chainKeys->Array.map(chainIdStr => {
    let chain = chainIdStr->ChainId.normalizeOrThrow

    if !(config.chainMap->ChainMap.has(chain)) {
      JsError.throwWithMessage(`Chain ${chainIdStr} is not configured in config.yaml`)
    }

    let processChainConfig = processConfigChains->Dict.getUnsafe(chainIdStr)
    let addressRows =
      addressRowsByChain
      ->Utils.Dict.dangerouslyGetNonOption(chainIdStr)
      ->Option.getOr(AddressRows.emptySeedRows())
    {
      Persistence.id: chain,
      startBlock: processChainConfig.startBlock,
      endBlock: processChainConfig.endBlock,
      sourceBlockNumber: processChainConfig.endBlock->Option.getOr(0),
      maxReorgDepth: 0, // No reorg support in test indexer
      progressBlockNumber: -1,
      numEventsProcessed: 0.,
      firstEventBlockNumber: None,
      timestampCaughtUpToHeadOrEndblock: None,
      addressRows,
    }
  })

  {
    cleanRun: true,
    contractMapping,
    envioInfo: Some(JSON.Encode.object(Dict.make())),
    cache: Dict.make(),
    chains,
    checkpointId: InternalTable.Checkpoints.initialCheckpointId,
    reorgCheckpoints: [],
  }
}

type rawChainConfig = {
  startBlock: option<int>,
  endBlock: option<int>,
  simulate: option<array<JSON.t>>,
}

let rawChainConfigSchema = S.schema(s => {
  startBlock: s.matches(S.option(S.int)),
  endBlock: s.matches(S.option(S.int)),
  simulate: s.matches(S.option(S.array(S.json(~validate=false)))),
})

let processConfigSchema = S.schema(s =>
  {
    "chains": s.matches(S.dict(rawChainConfigSchema)),
  }
)

let getSimulateEndBlock = (
  ~simulateItems: array<JSON.t>,
  ~config: Config.t,
  ~startBlock: int,
): int => {
  let maxBlock = ref(startBlock)
  let blockNumberKey = switch config.ecosystem.name {
  | Svm => "slot"
  | _ => config.ecosystem.blockNumberName
  }
  let bump = (n: option<int>) =>
    switch n {
    | Some(v) if v > maxBlock.contents => maxBlock := v
    | _ => ()
    }
  let getInt = (d: dict<JSON.t>, key) =>
    d
    ->Dict.get(key)
    ->Option.flatMap(v => v->(Utils.magic: JSON.t => Nullable.t<int>)->Nullable.toOption)
  simulateItems->Array.forEach(rawJson => {
    let itemDict = rawJson->(Utils.magic: JSON.t => dict<JSON.t>)
    // SVM items carry the slot at the top level (`block.slot` is the override).
    switch config.ecosystem.name {
    | Svm => itemDict->getInt("slot")->bump
    | _ => ()
    }
    let blockJson: option<JSON.t> =
      (rawJson->(Utils.magic: JSON.t => {..}))["block"]
      ->(Utils.magic: 'a => Nullable.t<JSON.t>)
      ->Nullable.toOption
    switch blockJson {
    | Some(bj) => bj->(Utils.magic: JSON.t => dict<JSON.t>)->getInt(blockNumberKey)->bump
    | None => ()
    }
  })
  maxBlock.contents
}

// Parse and validate block range from raw processConfig for a single chain.
// Resolves optional startBlock/endBlock with defaults and validates the range.
let parseBlockRange = (
  ~chainIdStr: string,
  ~config: Config.t,
  ~rawChainConfig: rawChainConfig,
  ~progressBlock: option<int>,
): chainConfig => {
  let chain = try chainIdStr->ChainId.normalizeOrThrow catch {
  | _ => JsError.throwWithMessage(`Invalid chain ID "${chainIdStr}": expected a numeric chain ID`)
  }
  if !(config.chainMap->ChainMap.has(chain)) {
    JsError.throwWithMessage(`Chain ${chainIdStr} is not configured in config.yaml`)
  }
  let configChain = config.chainMap->ChainMap.get(chain)

  let startBlock = switch rawChainConfig.startBlock {
  | Some(sb) => sb
  | None =>
    switch progressBlock {
    | Some(prevEndBlock) => prevEndBlock + 1
    | None => configChain.startBlock
    }
  }

  let endBlock = switch rawChainConfig.endBlock {
  | Some(eb) => Some(eb)
  | None if rawChainConfig.simulate->Option.isSome =>
    Some(
      getSimulateEndBlock(
        ~simulateItems=rawChainConfig.simulate->Option.getOrThrow,
        ~config,
        ~startBlock,
      ),
    )
  | None => None // auto-exit mode: will fetch first block with events and exit
  }

  if startBlock < configChain.startBlock {
    JsError.throwWithMessage(
      `Invalid block range for chain ${chainIdStr}: startBlock (${startBlock->Int.toString}) is less than config.startBlock (${configChain.startBlock->Int.toString}). ` ++
      `Either use startBlock >= ${configChain.startBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  }

  switch (endBlock, configChain.endBlock) {
  | (Some(eb), Some(configEndBlock)) if eb > configEndBlock =>
    JsError.throwWithMessage(
      `Invalid block range for chain ${chainIdStr}: endBlock (${eb->Int.toString}) exceeds config.endBlock (${configEndBlock->Int.toString}). ` ++
      `Either use endBlock <= ${configEndBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  | _ => ()
  }

  switch progressBlock {
  | Some(prevEndBlock) if startBlock <= prevEndBlock =>
    JsError.throwWithMessage(
      `Invalid block range for chain ${chainIdStr}: startBlock (${startBlock->Int.toString}) must be greater than previously processed endBlock (${prevEndBlock->Int.toString}). ` ++
      `Either use startBlock > ${prevEndBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  | _ => ()
  }

  {startBlock, endBlock}
}

// The store owns its entities. Copy on the boundary with user code — both when
// handing one out (get/getAll/getOrThrow) and when taking one in (set) — so a
// user mutating a returned entity, or an object they passed to `set`, can't
// corrupt the in-memory store. The copy is shallow (matching InMemoryTable):
// scalar fields (string/bigint/BigDecimal) are immutable, but array-valued
// fields still share the backing array, so in-place mutation of those leaks.
let copyEntity = (entity: Internal.entity): Internal.entity =>
  entity
  ->(Utils.magic: Internal.entity => dict<unknown>)
  ->Utils.Dict.shallowCopy
  ->(Utils.magic: dict<unknown> => Internal.entity)

// Entity operations for direct manipulation outside of handlers. Unlike a
// handler, which always runs on a known chain, these are chain-agnostic — so a
// per-chain entity is looked up across every chain and an id present on more
// than one is an error rather than an arbitrary pick.
let getEntityFromState = (
  ~state: testIndexerState,
  ~entityConfig: Internal.entityConfig,
  ~entityId: string,
  ~methodName: string,
): option<Internal.entity> => {
  if state.processInProgress {
    JsError.throwWithMessage(
      `Cannot call ${entityConfig.name}.${methodName}() while indexer.process() is running. ` ++ "Wait for process() to complete before accessing entities directly.",
    )
  }
  let entityDict = state.entities->Dict.get(entityConfig.name)->Option.getOr(Dict.make())
  switch entityConfig.table->Table.getChainIdField {
  | None => entityDict->Dict.get(entityId)->Option.map(copyEntity)
  | Some(field) =>
    let matches = entityDict->Dict.valuesToArray->Array.filter(entity => entity.id === entityId)
    switch matches {
    | [] => None
    | [entity] => Some(copyEntity(entity))
    | _ =>
      let chains =
        matches
        ->Array.map(entity =>
          entity->readChainId(~field)->Option.mapOr("unknown", ChainId.toString)
        )
        ->Array.join(", ")
      JsError.throwWithMessage(
        `Entity \`${entityConfig.name}\` with id \`${entityId}\` exists on multiple chains (${chains}) — use getWhere({${field.fieldName}: {_eq: ...}}) to pick one.`,
      )
    }
  }
}

let makeEntityGet = (~state: testIndexerState, ~entityConfig: Internal.entityConfig): (
  string => promise<option<Internal.entity>>
) => {
  entityId => {
    Promise.resolve(getEntityFromState(~state, ~entityConfig, ~entityId, ~methodName="get"))
  }
}

let makeEntityGetOrThrow = (~state: testIndexerState, ~entityConfig: Internal.entityConfig): (
  (string, ~message: string=?) => promise<Internal.entity>
) => {
  (entityId, ~message=?) => {
    switch getEntityFromState(~state, ~entityConfig, ~entityId, ~methodName="getOrThrow") {
    | Some(entity) => Promise.resolve(entity)
    | None =>
      let msg = switch message {
      | Some(m) => m
      | None => `Entity ${entityConfig.name} with id ${entityId} not found`
      }
      JsError.throwWithMessage(msg)
    }
  }
}

let makeEntitySet = (~state: testIndexerState, ~entityConfig: Internal.entityConfig): (
  Internal.entity => unit
) => {
  entity => {
    if state.processInProgress {
      JsError.throwWithMessage(
        `Cannot call ${entityConfig.name}.set() while indexer.process() is running. ` ++ "Wait for process() to complete before modifying entities directly.",
      )
    }
    let entityDict = switch state.entities->Dict.get(entityConfig.name) {
    | Some(dict) => dict
    | None =>
      let dict = Dict.make()
      state.entities->Dict.set(entityConfig.name, dict)
      dict
    }
    // Outside a handler there's no chain in context, so a per-chain entity has
    // to say which chain the row belongs to.
    let scope = switch entityConfig.table->Table.getChainIdField {
    | None => Internal.CrossChain
    | Some(field) =>
      switch entity->readChainId(~field) {
      | Some(chainId) => Internal.Chain(chainId)
      | None =>
        JsError.throwWithMessage(
          `${entityConfig.name}.set() requires a \`${field.fieldName}\` because the entity is per-chain. Pass it alongside the entity fields.`,
        )
      }
    }
    entityDict->Dict.set(
      rowKey(~scope, ~entityId=entity.id->EntityId.unsafeOfString),
      copyEntity(entity),
    )
  }
}

let makeEntityGetAll = (~state: testIndexerState, ~entityConfig: Internal.entityConfig): (
  unit => promise<array<Internal.entity>>
) => {
  () => {
    if state.processInProgress {
      JsError.throwWithMessage(
        `Cannot call ${entityConfig.name}.getAll() while indexer.process() is running. ` ++ "Wait for process() to complete before accessing entities directly.",
      )
    }
    let entityDict = state.entities->Dict.get(entityConfig.name)->Option.getOr(Dict.make())
    Promise.resolve(entityDict->Dict.valuesToArray->Array.map(copyEntity))
  }
}

// The same filter syntax as `context.X.getWhere` in a handler, matched against
// the store instead of a database. A per-chain entity's rows carry their chain
// id, so `{chainId: {_eq: 1}}` is what narrows an id that exists on several
// chains.
let makeEntityGetWhere = (~state: testIndexerState, ~entityConfig: Internal.entityConfig): (
  dict<dict<unknown>> => promise<array<Internal.entity>>
) => {
  filter => {
    if state.processInProgress {
      JsError.throwWithMessage(
        `Cannot call ${entityConfig.name}.getWhere() while indexer.process() is running. ` ++ "Wait for process() to complete before accessing entities directly.",
      )
    }
    let filters =
      filter->EntityFilter.parseGetWhereOrThrow(
        ~entityName=entityConfig.name,
        ~table=entityConfig.table,
      )
    let entityDict = state.entities->Dict.get(entityConfig.name)->Option.getOr(Dict.make())
    // parseGetWhereOrThrow expands an operator group into alternatives whose
    // matches are disjoint, so the union needs no dedup.
    Promise.resolve(
      entityDict
      ->Dict.valuesToArray
      ->Array.filter(entity => {
        let entityAsDict = entity->(Utils.magic: Internal.entity => dict<EntityFilter.FieldValue.t>)
        filters->Array.some(filter => filter->EntityFilter.matches(~entity=entityAsDict))
      })
      ->Array.map(copyEntity),
    )
  }
}

type entityOperations = {
  get: string => promise<option<Internal.entity>>,
  getAll: unit => promise<array<Internal.entity>>,
  getWhere: dict<dict<unknown>> => promise<array<Internal.entity>>,
  getOrThrow: (string, ~message: string=?) => promise<Internal.entity>,
  set: Internal.entity => unit,
}

// Adapt the real storage interface to the in-memory entity store. In-process
// there's no worker boundary, so entities are stored and loaded decoded — no
// JSON serialization round-trip.
let makeInMemoryStorage = (~state: testIndexerState): Persistence.storage => {
  name: "test-inmemory",
  isInitialized: async () => true,
  // The runner injects the config-derived initial state by setting
  // `persistence.storageStatus = Ready(...)` directly, bypassing `Persistence.init`,
  // so neither of these is reached.
  initialize: async (
    ~chainConfigs as _=?,
    ~entities as _=?,
    ~enums as _=?,
    ~contractMapping as _,
    ~envioInfo as _,
  ) =>
    JsError.throwWithMessage(
      "TestIndexer: initialize should not be called; the initial state is derived from config.",
    ),
  resumeInitialState: async () =>
    JsError.throwWithMessage(
      "TestIndexer: resumeInitialState should not be called; the initial state is derived from config.",
    ),
  loadOrThrow: async (~filter, ~table: Table.table) =>
    state
    ->handleLoad(~tableName=table.tableName, ~filter)
    ->(Utils.magic: array<Internal.entity> => array<unknown>),
  // The in-memory storage has no indexes to build, and it's always ready.
  ensureQueryIndexes: async (~table as _, ~filters as _) => (),
  ensureSchemaIndexes: async (~entities as _) => (),
  finalizeBackfill: async (~entities as _, ~chainIds as _, ~readyAt as _) => (),
  writeBatch: async (
    ~batch,
    ~rollback as _,
    ~isInReorgThreshold as _,
    ~config,
    ~allEntities as _,
    ~updatedEffectsCache as _,
    ~updatedEntities,
    ~registeredAddresses,
    ~chainMetaData as _,
    ~onWrite as _,
  ) =>
    state->handleWriteBatch(
      ~config,
      ~updatedEntities,
      ~registeredAddresses,
      ~checkpointIds=batch.checkpointIds,
      ~checkpointChainIds=batch.checkpointChainIds,
      ~checkpointBlockNumbers=batch.checkpointBlockNumbers,
      ~checkpointEventsProcessed=batch.checkpointEventsProcessed,
    ),
  dumpEffectCache: async () => (),
  reset: async () => (),
  setChainMeta: async _ => Obj.magic(),
  pruneStaleCheckpoints: async (~safeCheckpointId as _) => (),
  pruneStaleEntityHistory: async (
    ~entityName as _,
    ~entityIndex as _,
    ~chainIdColumn as _,
    ~safeCheckpointId as _,
  ) => (),
  getRollbackTargetCheckpoint: async (~reorgChainId as _, ~lastKnownValidBlockNumber as _) =>
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. The runner forces rollbackOnReorg off, so this should be unreachable.",
    ),
  getRollbackProgressDiff: async (~scope as _, ~rollbackTargetCheckpointId as _) =>
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. The runner forces rollbackOnReorg off, so this should be unreachable.",
    ),
  getRollbackData: async (~entityConfig as _, ~scope as _, ~rollbackTargetCheckpointId as _) =>
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. The runner forces rollbackOnReorg off, so this should be unreachable.",
    ),
  close: async () => (),
}

// Copy the per-chain registration arrays so a process() run's simulate-source
// additions (SimulateItems.patchConfig pushes onEventRegistrations) never
// mutate the shared base registration — lets independent createTestIndexer runs
// proceed in parallel without clobbering each other's registrations.
let cloneRegistrations = (
  base: HandlerRegister.registrationsByChainId,
): HandlerRegister.registrationsByChainId => {
  let clone = Dict.make()
  base
  ->Dict.toArray
  ->Array.forEach(((chainIdStr, chainRegistrations: HandlerRegister.chainRegistrations)) =>
    clone->Dict.set(
      chainIdStr,
      {
        HandlerRegister.onEventRegistrations: chainRegistrations.onEventRegistrations->Array.copy,
        onBlockRegistrations: chainRegistrations.onBlockRegistrations->Array.copy,
      },
    )
  )
  clone
}

// User handlers register into the process-global HandlerRegister as an import
// side effect. Capture the resolved registrations once per process (imports are
// module-cached anyway) and reuse them across every createTestIndexer run, so
// the global registration cycle runs a single time and never races.
let registrationsRef: ref<option<promise<HandlerRegister.registrationsByChainId>>> = ref(None)
let getRegistrations = (~config) =>
  switch registrationsRef.contents {
  | Some(promise) => promise
  | None =>
    let promise = HandlerLoader.registerAllHandlers(~config)
    registrationsRef := Some(promise)
    promise
  }

let createTestIndexer = (): t<'processConfig> => {
  let config = Config.load()
  let allEntities = config.userEntities
  let entities = Dict.make()
  let entityConfigs = Dict.make()
  allEntities->Array.forEach(entityConfig => {
    entities->Dict.set(entityConfig.name, Dict.make())
    entityConfigs->Dict.set(entityConfig.name, entityConfig)
  })

  let chainConfigs = config.chainMap->ChainMap.values
  let contractMapping = config.contractMapping
  let ecosystem = config.ecosystem.name
  let addresses = AddressRows.Table.make()
  addresses->ChainState.seedConfigAddresses(~chainConfigs, ~ecosystem, ~contractMapping)

  let state = {
    processInProgress: false,
    progressBlockByChain: Dict.make(),
    entities,
    entityConfigs,
    addresses,
    contractMapping,
    processChanges: [],
  }

  // Per-instance in-memory storage over `state.entities`. Separate indexers
  // get separate storages, so independent indexers run in parallel without
  // shared mutable state.
  let storage = makeInMemoryStorage(~state)
  let persistence = Persistence.make(
    ~userEntities=config.userEntities,
    ~allEnums=config.allEnums,
    ~storage,
  )

  // Silence logs by default in test mode unless LOG_LEVEL is explicitly set.
  switch Env.userLogLevel {
  | None => Logging.setLogLevel(#silent)
  | Some(_) => ()
  }

  // Build entity operations for each user entity
  let entityOpsDict: dict<entityOperations> = Dict.make()
  allEntities->Array.forEach(entityConfig => {
    entityOpsDict->Dict.set(
      entityConfig.name,
      {
        get: makeEntityGet(~state, ~entityConfig),
        getAll: makeEntityGetAll(~state, ~entityConfig),
        getWhere: makeEntityGetWhere(~state, ~entityConfig),
        getOrThrow: makeEntityGetOrThrow(~state, ~entityConfig),
        set: makeEntitySet(~state, ~entityConfig),
      },
    )
  })

  // Build chain info from config (similar to Main.getGlobalIndexer but static)
  let chainIds = []
  let chains = Utils.Object.createNullObject()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    let chainIdStr = chainConfig.id->ChainId.toString
    chainIds->Array.push(chainConfig.id)->ignore

    let chainObj = Utils.Object.createNullObject()
    chainObj
    ->Utils.Object.definePropertyWithValue("id", {enumerable: true, value: chainConfig.id})
    ->Utils.Object.definePropertyWithValue(
      "startBlock",
      {enumerable: true, value: chainConfig.startBlock},
    )
    ->Utils.Object.definePropertyWithValue(
      "endBlock",
      {enumerable: true, value: chainConfig.endBlock},
    )
    ->Utils.Object.definePropertyWithValue("name", {enumerable: true, value: chainConfig.name})
    ->Utils.Object.definePropertyWithValue("isRealtime", {enumerable: true, value: false})
    ->ignore

    // Add contracts to chain object
    chainConfig.contracts->Array.forEach(contract => {
      let contractObj = Utils.Object.createNullObject()
      contractObj
      ->Utils.Object.definePropertyWithValue("name", {enumerable: true, value: contract.name})
      ->Utils.Object.definePropertyWithValue("abi", {enumerable: true, value: contract.abi})
      ->Utils.Object.defineProperty(
        "addresses",
        {
          enumerable: true,
          get: () => {
            if state.processInProgress {
              JsError.throwWithMessage(
                `Cannot access ${contract.name}.addresses while indexer.process() is running. ` ++ "Wait for process() to complete before reading contract addresses.",
              )
            }
            let contractId = state.contractMapping->ContractMapping.idOfOrThrow(contract.name)
            state.addresses
            ->AddressRows.Table.rows
            ->Array.filter(row => row.chainId === chainConfig.id && row.contractId === contractId)
            ->renderRows(~config)
          },
        },
      )
      ->ignore

      chainObj
      ->Utils.Object.definePropertyWithValue(contract.name, {enumerable: true, value: contractObj})
      ->ignore
    })

    chains
    ->Utils.Object.definePropertyWithValue(chainIdStr, {enumerable: true, value: chainObj})
    ->ignore

    if chainConfig.name !== chainIdStr {
      chains
      ->Utils.Object.definePropertyWithValue(chainConfig.name, {enumerable: false, value: chainObj})
      ->ignore
    }
  })

  // Build the result object with process + entity operations + chain info
  let result: dict<unknown> = Dict.make()
  result->Dict.set("chainIds", chainIds->(Utils.magic: array<ChainId.t> => unknown))
  result->Dict.set("chains", chains->(Utils.magic: {..} => unknown))
  entityOpsDict
  ->Dict.toArray
  ->Array.forEach(((name, ops)) => {
    // Expose the capitalized accessor (indexer.Pool_snapshots) the generated
    // types declare, matching the handler-context keys.
    result->Dict.set(name->Utils.String.capitalize, ops->(Utils.magic: entityOperations => unknown))
  })

  result->Dict.set(
    "process",
    (
      processConfig => {
        // Check if already processing
        if state.processInProgress {
          JsError.throwWithMessage(
            "createTestIndexer process is already running. Only one process call is allowed at a time",
          )
        }

        // Parse and validate processConfig
        let parsedConfig = try processConfig->S.parseOrThrow(processConfigSchema) catch {
        | S.Raised(exn) =>
          JsError.throwWithMessage(
            `Invalid processConfig: ${exn->Utils.prettifyExn->(Utils.magic: exn => string)}`,
          )
        }
        let rawChains = parsedConfig["chains"]
        let chainKeys = rawChains->Dict.keysToArray

        if chainKeys->Array.length === 0 {
          JsError.throwWithMessage("createTestIndexer requires at least one chain to be defined")
        }

        // Sort chain keys by chain ID for deterministic ordering
        let sortedChainKeys = chainKeys->Array.copy
        sortedChainKeys->Array.sort((a, b) => {
          let aId = a->Int.fromString->Option.getOr(0)
          let bId = b->Int.fromString->Option.getOr(0)
          Int.compare(aId, bId)
        })

        // Parse and validate the block ranges upfront before running any chain.
        let chainEntries = sortedChainKeys->Array.map(chainIdStr => {
          let rawChainConfig = rawChains->Dict.getUnsafe(chainIdStr)
          if chainIdStr->Int.fromString->Option.isNone {
            JsError.throwWithMessage(
              `Invalid chain ID "${chainIdStr}": expected a numeric chain ID`,
            )
          }
          let processChainConfig = parseBlockRange(
            ~chainIdStr,
            ~config,
            ~rawChainConfig,
            ~progressBlock=state.progressBlockByChain->Dict.get(chainIdStr),
          )
          (chainIdStr, rawChainConfig, processChainConfig)
        })

        // Reset processChanges for this run
        state.processChanges = []

        let runChainInProcess = async ((
          chainIdStr,
          rawChainConfig: rawChainConfig,
          processChainConfig,
        )) => {
          // Build initialState from resolved block range. Rebuilt per chain so
          // later chains in the same process() call see contracts registered
          // by earlier ones.
          let chains: dict<chainConfig> = Dict.make()
          chains->Dict.set(chainIdStr, processChainConfig)
          let initialState = makeInitialState(
            ~config,
            ~processConfigChains=chains,
            ~addressRowsByChain=addressRowsByChain(state),
            ~contractMapping=state.contractMapping,
          )

          // No endBlock means auto-exit mode: process one block checkpoint at a
          // time and stop after the first block with events.
          let exitAfterFirstEventBlock = processChainConfig.endBlock->Option.isNone

          // Rebuild the processConfig JSON that SimulateItems.patchConfig reads
          // to turn `simulate` items into a SimulateSource for the chain.
          let resolvedChainDict: dict<unknown> = Dict.make()
          resolvedChainDict->Dict.set(
            "startBlock",
            processChainConfig.startBlock->(Utils.magic: int => unknown),
          )
          switch processChainConfig.endBlock {
          | Some(eb) => resolvedChainDict->Dict.set("endBlock", eb->(Utils.magic: int => unknown))
          | None => ()
          }
          switch rawChainConfig.simulate {
          | Some(s) =>
            resolvedChainDict->Dict.set("simulate", s->(Utils.magic: array<JSON.t> => unknown))
          | None => ()
          }
          let resolvedChainsDict: dict<unknown> = Dict.make()
          resolvedChainsDict->Dict.set(
            chainIdStr,
            resolvedChainDict->(Utils.magic: dict<unknown> => unknown),
          )
          let processConfigJson =
            {"chains": resolvedChainsDict}->(Utils.magic: {"chains": dict<unknown>} => JSON.t)

          // Each run gets its own copy of the shared base registration so the
          // simulate-source registration it appends stays isolated.
          let registrationsByChainId = cloneRegistrations(await getRegistrations(~config))
          let patchedConfig: Config.t = SimulateItems.patchConfig(
            ~config,
            ~processConfig=processConfigJson,
            ~registrationsByChainId,
          )
          let runConfig = {...patchedConfig, shouldRollbackOnReorg: false}
          let runConfig = exitAfterFirstEventBlock ? {...runConfig, batchSize: 1} : runConfig

          // Bypass Persistence.init: hand the loop the config-derived initial
          // state directly (never a real DB) and mark the storage Ready so
          // writes go through.
          persistence.storageStatus = Ready(initialState)

          let indexerStateRef = ref(None)
          // Stop the loop and let any in-flight processing/write settle, so a
          // finished run leaves nothing driving the shared state into the next.
          let cleanup = async () => {
            switch indexerStateRef.contents {
            | Some(indexerState) =>
              indexerState->IndexerState.stop
              while (
                indexerState->IndexerState.isProcessing ||
                  indexerState->IndexerState.writeFiber->Option.isSome
              ) {
                switch indexerState->IndexerState.writeFiber {
                // Await the in-flight write directly; only fall back to a tick
                // yield while processing hasn't yet spawned a write fiber.
                | Some(fiber) => await fiber
                | None => await Utils.delay(0)
                }
              }
            | None => ()
            }
          }
          try {
            await Promise.make((resolve, reject) => {
              let indexerState = IndexerState.makeFromDbState(
                ~config=runConfig,
                ~persistence,
                ~initialState,
                ~registrationsByChainId,
                ~exitAfterFirstEventBlock,
                ~onError=errHandler => {
                  errHandler->ErrorHandling.log
                  reject(errHandler.exn->Utils.prettifyExn)
                },
                // Caught up: resolve the run instead of exiting the process.
                ~onExit=() => resolve(),
              )
              indexerStateRef := Some(indexerState)
              indexerState->IndexerLoop.start
            })
            await cleanup()
          } catch {
          | exn =>
            await cleanup()
            throw(exn)
          }
        }

        // Set flag before starting the run
        state.processInProgress = true

        // Run chains sequentially, one at a time
        let rec runChains = idx => {
          if idx >= chainEntries->Array.length {
            state.processInProgress = false
            Promise.resolve({changes: state.processChanges})
          } else {
            runChainInProcess(chainEntries->Array.getUnsafe(idx))->Promise.then(_ =>
              runChains(idx + 1)
            )
          }
        }

        runChains(0)->Promise.catch(err => {
          state.processInProgress = false
          Promise.reject(err->Utils.prettifyExn)
        })
      }
    )->(Utils.magic: ('a => promise<processResult>) => unknown),
  )

  result->(Utils.magic: dict<unknown> => t<'processConfig>)
}
