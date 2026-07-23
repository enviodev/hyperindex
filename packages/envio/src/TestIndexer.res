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

// Internal type used for block range validation and state management
type chainConfig = {
  startBlock: int,
  endBlock: option<int>,
}

type processResult = {changes: array<unknown>}

type t<'processConfig> = {process: 'processConfig => promise<processResult>}

type entityChange = {
  sets: array<unknown>,
  deleted: array<string>,
}

type testIndexerState = {
  mutable processInProgress: bool,
  progressBlockByChain: dict<int>,
  // Store decoded entities (not JSON) for proper comparison operations
  entities: dict<dict<Internal.entity>>,
  entityConfigs: dict<Internal.entityConfig>,
  mutable processChanges: array<unknown>,
}

// Cast Internal.entity back to EnvioAddresses.t
external castToEnvioAddresses: Internal.entity => InternalTable.EnvioAddresses.t = "%identity"

let toIndexingAddress = (dc: InternalTable.EnvioAddresses.t): Internal.indexingAddress => {
  address: dc->Config.EnvioAddresses.getAddress,
  contractName: dc.contractName,
  registrationBlock: dc.registrationBlock,
}

// All indexing addresses (config-seeded + dynamically registered) grouped by
// chain id string, derived from the envio_addresses entities.
let getIndexingAddressesByChain = (state: testIndexerState): dict<
  array<Internal.indexingAddress>,
> => {
  let byChain = Dict.make()
  switch state.entities->Dict.get(InternalTable.EnvioAddresses.name) {
  | Some(dcDict) =>
    dcDict
    ->Dict.valuesToArray
    ->Array.forEach(entity => {
      let dc = entity->castToEnvioAddresses
      let chainIdStr = dc.chainId->Int.toString
      let contracts = switch byChain->Dict.get(chainIdStr) {
      | Some(arr) => arr
      | None =>
        let arr = []
        byChain->Dict.set(chainIdStr, arr)
        arr
      }
      contracts->Array.push(dc->toIndexingAddress)->ignore
    })
  | None => ()
  }
  byChain
}

let handleLoad = (state: testIndexerState, ~tableName: string, ~filter: EntityFilter.t): array<
  Internal.entity,
> => {
  // Loads for non-entity tables (e.g. effect caches `envio_effect_<name>`) reach
  // here too. TestIndexer never persists those, so there's nothing to return —
  // an empty result makes the effect recompute instead of crashing on a missing
  // entityConfig.
  switch state.entityConfigs->Dict.get(tableName) {
  | None => []
  | Some(_) =>
    let entityDict = state.entities->Dict.get(tableName)->Option.getOr(Dict.make())
    entityDict
    ->Dict.valuesToArray
    ->Array.filter(entity => {
      // The store holds decoded entities and the filter carries decoded values,
      // so compare directly (same approach as InMemoryTable) — no JSON round-trip.
      let entityAsDict = entity->(Utils.magic: Internal.entity => dict<EntityFilter.FieldValue.t>)
      filter->EntityFilter.matches(~entity=entityAsDict)
    })
  }
}

let handleWriteBatch = (
  state: testIndexerState,
  ~updatedEntities: array<Persistence.updatedEntity>,
  ~checkpointIds: array<bigint>,
  ~checkpointChainIds: array<int>,
  ~checkpointBlockNumbers: array<int>,
  ~checkpointEventsProcessed: array<int>,
): unit => {
  // Group entity changes by checkpointId
  // checkpointId -> entityName -> entityChange
  let changesByCheckpoint: dict<dict<entityChange>> = Dict.make()

  updatedEntities->Array.forEach(({entityConfig, changes}: Persistence.updatedEntity) => {
    let entityName = entityConfig.name
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
        // BigDecimal) work on real values.
        entityDict->Dict.set(entityId, entity)
        entityChangeFor(checkpointId).sets->Array.push(entity->Utils.magic)->ignore
      | Delete({entityId, checkpointId}) =>
        Dict.delete(entityDict->Obj.magic, entityId)
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
      checkpointChainIds->Array.getUnsafe(i)->Int.toString,
      checkpointBlockNumbers->Array.getUnsafe(i),
    )

    // Add checkpoint metadata
    change->Dict.set("block", checkpointBlockNumbers->Array.getUnsafe(i)->Utils.magic)
    change->Dict.set("chainId", checkpointChainIds->Array.getUnsafe(i)->Utils.magic)
    change->Dict.set("eventsProcessed", checkpointEventsProcessed->Array.getUnsafe(i)->Utils.magic)

    // Add entity changes for this checkpoint
    let checkpointKey = checkpointId->BigInt.toString
    switch changesByCheckpoint->Dict.get(checkpointKey) {
    | Some(entityChanges) =>
      entityChanges
      ->Dict.toArray
      ->Array.forEach(((entityName, {sets, deleted})) => {
        // Transform envio_addresses to addresses with simplified structure
        if entityName === InternalTable.EnvioAddresses.name {
          let entityObj: dict<unknown> = Dict.make()
          if sets->Array.length > 0 {
            // Transform sets to simplified {address, contract} objects
            let simplifiedSets = sets->Array.map(entity => {
              let dc = entity->Utils.magic->castToEnvioAddresses
              {"address": dc->Config.EnvioAddresses.getAddress, "contract": dc.contractName}
            })
            entityObj->Dict.set(
              "sets",
              simplifiedSets->(
                Utils.magic: array<{"address": Address.t, "contract": string}> => unknown
              ),
            )
          }
          // Note: deleted is not relevant for addresses since we use address string directly
          change->Dict.set("addresses", entityObj->(Utils.magic: dict<unknown> => unknown))
        } else {
          let entityObj: dict<unknown> = Dict.make()
          if sets->Array.length > 0 {
            entityObj->Dict.set("sets", sets->(Utils.magic: array<unknown> => unknown))
          }
          if deleted->Array.length > 0 {
            entityObj->Dict.set("deleted", deleted->(Utils.magic: array<string> => unknown))
          }
          change->Dict.set(entityName, entityObj->(Utils.magic: dict<unknown> => unknown))
        }
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
  ~indexingAddressesByChain: dict<array<Internal.indexingAddress>>,
): Persistence.initialState => {
  let chainKeys = processConfigChains->Dict.keysToArray
  let chains = chainKeys->Array.map(chainIdStr => {
    let chainId = chainIdStr->Int.fromString->Option.getOr(0)
    let chain = ChainMap.Chain.makeUnsafe(~chainId)

    if !(config.chainMap->ChainMap.has(chain)) {
      JsError.throwWithMessage(`Chain ${chainIdStr} is not configured in config.yaml`)
    }

    let processChainConfig = processConfigChains->Dict.getUnsafe(chainIdStr)
    let indexingAddresses = indexingAddressesByChain->Dict.get(chainIdStr)->Option.getOr([])
    {
      Persistence.id: chainId,
      startBlock: processChainConfig.startBlock,
      endBlock: processChainConfig.endBlock,
      sourceBlockNumber: processChainConfig.endBlock->Option.getOr(0),
      maxReorgDepth: 0, // No reorg support in test indexer
      progressBlockNumber: -1,
      numEventsProcessed: 0.,
      firstEventBlockNumber: None,
      timestampCaughtUpToHeadOrEndblock: None,
      indexingAddresses,
    }
  })

  {
    cleanRun: true,
    cache: Dict.make(),
    chains,
    checkpointId: InternalTable.Checkpoints.initialCheckpointId,
    reorgCheckpoints: [],
    envioInfo: Some(Config.getPublicConfigJson()->Config.stripSensitiveData),
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
  simulateItems->Array.forEach(rawJson => {
    let blockJson: option<JSON.t> =
      (rawJson->(Utils.magic: JSON.t => {..}))["block"]
      ->(Utils.magic: 'a => Nullable.t<JSON.t>)
      ->Nullable.toOption
    switch blockJson {
    | Some(bj) =>
      let blockDict = bj->(Utils.magic: JSON.t => dict<JSON.t>)
      let n: option<int> =
        blockDict
        ->Dict.get(config.ecosystem.blockNumberName)
        ->Option.flatMap(v => v->(Utils.magic: JSON.t => Nullable.t<int>)->Nullable.toOption)
      switch n {
      | Some(v) if v > maxBlock.contents => maxBlock := v
      | _ => ()
      }
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
  let chainId = switch chainIdStr->Int.fromString {
  | Some(id) => id
  | None =>
    JsError.throwWithMessage(`Invalid chain ID "${chainIdStr}": expected a numeric chain ID`)
  }
  let chain = ChainMap.Chain.makeUnsafe(~chainId)
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
// corrupt the in-memory store. Shallow is enough: entity fields are immutable
// scalar values (string/bigint/BigDecimal), matching InMemoryTable.
let copyEntity = (entity: Internal.entity): Internal.entity =>
  entity
  ->(Utils.magic: Internal.entity => dict<unknown>)
  ->Utils.Dict.shallowCopy
  ->(Utils.magic: dict<unknown> => Internal.entity)

// Entity operations for direct manipulation outside of handlers
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
  entityDict->Dict.get(entityId)->Option.map(copyEntity)
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
    entityDict->Dict.set(entity.id, copyEntity(entity))
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

type entityOperations = {
  get: string => promise<option<Internal.entity>>,
  getAll: unit => promise<array<Internal.entity>>,
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
  initialize: async (~chainConfigs as _=?, ~entities as _=?, ~enums as _=?, ~envioInfo as _) =>
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
  writeBatch: async (
    ~batch,
    ~rollback as _,
    ~isInReorgThreshold as _,
    ~config as _,
    ~allEntities as _,
    ~updatedEffectsCache as _,
    ~updatedEntities,
    ~chainMetaData as _,
    ~onWrite as _,
  ) =>
    state->handleWriteBatch(
      ~updatedEntities,
      ~checkpointIds=batch.checkpointIds,
      ~checkpointChainIds=batch.checkpointChainIds,
      ~checkpointBlockNumbers=batch.checkpointBlockNumbers,
      ~checkpointEventsProcessed=batch.checkpointEventsProcessed,
    ),
  dumpEffectCache: async () => (),
  reset: async () => (),
  setChainMeta: async _ => Obj.magic(),
  pruneStaleCheckpoints: async (~safeCheckpointId as _) => (),
  pruneStaleEntityHistory: async (~entityName as _, ~entityIndex as _, ~safeCheckpointId as _) =>
    (),
  getRollbackTargetCheckpoint: async (~reorgChainId as _, ~lastKnownValidBlockNumber as _) =>
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
    ),
  getRollbackProgressDiff: async (~rollbackTargetCheckpointId as _) =>
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
    ),
  getRollbackData: async (~entityConfig as _, ~rollbackTargetCheckpointId as _) =>
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
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
  let allEntities = config.allEntities
  let entities = Dict.make()
  let entityConfigs = Dict.make()
  allEntities->Array.forEach(entityConfig => {
    entities->Dict.set(entityConfig.name, Dict.make())
    entityConfigs->Dict.set(entityConfig.name, entityConfig)
  })

  // Populate config addresses into the entity dict, mirroring PgStorage.initialize
  let envioAddressesDict = entities->Dict.getUnsafe(InternalTable.EnvioAddresses.name)
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    chainConfig.contracts->Array.forEach(contract => {
      contract.addresses->Array.forEach(
        address => {
          let entity: InternalTable.EnvioAddresses.t = {
            id: Config.EnvioAddresses.makeId(~chainId=chainConfig.id, ~address),
            chainId: chainConfig.id,
            contractName: contract.name,
            registrationBlock: -1,
            registrationLogIndex: -1,
          }
          envioAddressesDict->Dict.set(entity.id, entity->Config.EnvioAddresses.castToInternal)
        },
      )
    })
  })

  let state = {
    processInProgress: false,
    progressBlockByChain: Dict.make(),
    entities,
    entityConfigs,
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
    // Only create ops for user entities (not internal tables like envio_addresses)
    if entityConfig.name !== InternalTable.EnvioAddresses.name {
      entityOpsDict->Dict.set(
        entityConfig.name,
        {
          get: makeEntityGet(~state, ~entityConfig),
          getAll: makeEntityGetAll(~state, ~entityConfig),
          getOrThrow: makeEntityGetOrThrow(~state, ~entityConfig),
          set: makeEntitySet(~state, ~entityConfig),
        },
      )
    }
  })

  // Build chain info from config (similar to Main.getGlobalIndexer but static)
  let chainIds = []
  let chains = Utils.Object.createNullObject()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    let chainIdStr = chainConfig.id->Int.toString
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
            getIndexingAddressesByChain(state)
            ->Dict.get(chainConfig.id->Int.toString)
            ->Option.getOr([])
            ->Array.filterMap(ia => ia.contractName === contract.name ? Some(ia.address) : None)
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
  result->Dict.set("chainIds", chainIds->(Utils.magic: array<int> => unknown))
  result->Dict.set("chains", chains->(Utils.magic: {..} => unknown))
  entityOpsDict
  ->Dict.toArray
  ->Array.forEach(((name, ops)) => {
    result->Dict.set(name, ops->(Utils.magic: entityOperations => unknown))
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

        // Parse and validate the block ranges upfront before starting any workers.
        let chainEntries = sortedChainKeys->Array.map(chainIdStr => {
          let rawChainConfig = rawChains->Dict.getUnsafe(chainIdStr)
          let chainId = switch chainIdStr->Int.fromString {
          | Some(id) => id
          | None =>
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
          (chainIdStr, chainId, rawChainConfig, processChainConfig)
        })

        // Reset processChanges for this run
        state.processChanges = []

        let runChainInProcess = async ((
          chainIdStr,
          _chainId,
          rawChainConfig: rawChainConfig,
          processChainConfig,
        )) => {
          // Build initialState from resolved block range. Rebuilt per chain so
          // later chains in the same process() call see contracts registered
          // by earlier ones.
          let chains: dict<chainConfig> = Dict.make()
          chains->Dict.set(chainIdStr, processChainConfig)
          let indexingAddressesByChain = getIndexingAddressesByChain(state)
          let initialState = makeInitialState(
            ~config,
            ~processConfigChains=chains,
            ~indexingAddressesByChain,
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
