open Belt

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
  endBlock: int,
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

// Cast Internal.entity back to DynamicContractRegistry.t
external castFromDcRegistry: Internal.entity => InternalTable.DynamicContractRegistry.t =
  "%identity"

// Convert DynamicContractRegistry.t to Internal.indexingContract
let toIndexingContract = (
  dc: InternalTable.DynamicContractRegistry.t,
): Internal.indexingContract => {
  address: dc.contractAddress,
  contractName: dc.contractName,
  startBlock: dc.registeringEventBlockNumber,
  registrationBlock: Some(dc.registeringEventBlockNumber),
}

let handleLoadByIds = (
  state: testIndexerState,
  ~tableName: string,
  ~ids: array<string>,
): Js.Json.t => {
  let entityDict = state.entities->Js.Dict.get(tableName)->Option.getWithDefault(Js.Dict.empty())
  let entityConfig = state.entityConfigs->Js.Dict.unsafeGet(tableName)
  let results = []
  ids->Array.forEach(id => {
    switch entityDict->Js.Dict.get(id) {
    | Some(entity) =>
      // Serialize entity back to JSON for worker thread
      let jsonEntity = entity->S.reverseConvertToJsonOrThrow(entityConfig.schema)
      results->Array.push(jsonEntity)->ignore
    | None => ()
    }
  })
  results->Js.Json.array
}

let handleLoadByField = (
  state: testIndexerState,
  ~tableName: string,
  ~fieldName: string,
  ~fieldValue: Js.Json.t,
  ~operator: Persistence.operator,
): Js.Json.t => {
  let entityDict = state.entities->Js.Dict.get(tableName)->Option.getWithDefault(Js.Dict.empty())
  let entityConfig = state.entityConfigs->Js.Dict.unsafeGet(tableName)
  let results = []

  // Get the field schema from the entity's table to properly parse the JSON field value
  let fieldSchema = switch entityConfig.table->Table.getFieldByName(fieldName) {
  | Some(Table.Field({fieldSchema})) => fieldSchema
  | _ => Js.Exn.raiseError(`Field ${fieldName} not found in entity ${tableName}`)
  }

  // Parse JSON field value to typed value using the field's schema
  let parsedFieldValue = fieldValue->S.convertOrThrow(fieldSchema)->TableIndices.FieldValue.castFrom

  // Compare using TableIndices.FieldValue logic (same approach as InMemoryTable)
  // This properly handles bigint and BigDecimal comparisons
  entityDict
  ->Js.Dict.values
  ->Array.forEach(entity => {
    // Cast entity to dict of field values (same approach as InMemoryTable)
    let entityAsDict = entity->(Utils.magic: Internal.entity => dict<TableIndices.FieldValue.t>)
    switch entityAsDict->Js.Dict.get(fieldName) {
    | Some(entityFieldValue) => {
        let matches = switch operator {
        | #"=" => entityFieldValue->TableIndices.FieldValue.eq(parsedFieldValue)
        | #">" => entityFieldValue->TableIndices.FieldValue.gt(parsedFieldValue)
        | #"<" => entityFieldValue->TableIndices.FieldValue.lt(parsedFieldValue)
        }
        if matches {
          // Serialize entity back to JSON for worker thread
          let jsonEntity = entity->S.reverseConvertToJsonOrThrow(entityConfig.schema)
          results->Array.push(jsonEntity)->ignore
        }
      }
    | None => ()
    }
  })

  results->Js.Json.array
}

let handleWriteBatch = (
  state: testIndexerState,
  ~updatedEntities: array<TestIndexerProxyStorage.serializableUpdatedEntity>,
  ~checkpointIds: array<bigint>,
  ~checkpointChainIds: array<int>,
  ~checkpointBlockNumbers: array<int>,
  ~checkpointBlockHashes: array<Js.Null.t<string>>,
  ~checkpointEventsProcessed: array<int>,
): unit => {
  // Group entity changes by checkpointId
  // checkpointId -> entityName -> entityChange
  let changesByCheckpoint: dict<dict<entityChange>> = Js.Dict.empty()

  updatedEntities->Array.forEach(({entityName, updates}) => {
    let entityDict = switch state.entities->Js.Dict.get(entityName) {
    | Some(dict) => dict
    | None =>
      let dict = Js.Dict.empty()
      state.entities->Js.Dict.set(entityName, dict)
      dict
    }
    let entityConfig = state.entityConfigs->Js.Dict.unsafeGet(entityName)

    updates->Array.forEach(update => {
      // Helper to process a single change (Set or Delete)
      let processChange = (change: TestIndexerProxyStorage.serializableChange) => {
        switch change {
        | Set({entityId, entity, checkpointId}) =>
          // Parse entity immediately to store decoded values for proper comparisons
          // (bigint/BigDecimal need actual values, not JSON strings)
          let parsedEntity = entity->S.parseOrThrow(entityConfig.schema)

          // Update entities dict with parsed entity for load operations
          entityDict->Js.Dict.set(entityId, parsedEntity)

          // Track change by checkpoint
          let checkpointKey = checkpointId->BigInt.toString
          let entityChanges = switch changesByCheckpoint->Js.Dict.get(checkpointKey) {
          | Some(changes) => changes
          | None =>
            let changes = Js.Dict.empty()
            changesByCheckpoint->Js.Dict.set(checkpointKey, changes)
            changes
          }
          let entityChange = switch entityChanges->Js.Dict.get(entityName) {
          | Some(change) => change
          | None =>
            let change = {sets: [], deleted: []}
            entityChanges->Js.Dict.set(entityName, change)
            change
          }
          entityChange.sets->Array.push(parsedEntity->Utils.magic)->ignore

        | Delete({entityId, checkpointId}) =>
          // Update entities dict for load operations
          Js.Dict.unsafeDeleteKey(entityDict->Obj.magic, entityId)

          // Track change by checkpoint
          let checkpointKey = checkpointId->BigInt.toString
          let entityChanges = switch changesByCheckpoint->Js.Dict.get(checkpointKey) {
          | Some(changes) => changes
          | None =>
            let changes = Js.Dict.empty()
            changesByCheckpoint->Js.Dict.set(checkpointKey, changes)
            changes
          }
          let entityChange = switch entityChanges->Js.Dict.get(entityName) {
          | Some(change) => change
          | None =>
            let change = {sets: [], deleted: []}
            entityChanges->Js.Dict.set(entityName, change)
            change
          }
          entityChange.deleted->Array.push(entityId)->ignore
        }
      }

      // Iterate over all history entries (mirroring PgStorage.res behavior)
      update.history->Array.forEach(processChange)

      // Also include latestChange if history is empty (fallback for backwards compatibility)
      if update.history->Array.length === 0 {
        processChange(update.latestChange)
      }
    })
  })

  // Build combined checkpoint + entity changes objects
  for i in 0 to checkpointIds->Array.length - 1 {
    let checkpointId = checkpointIds->Array.getUnsafe(i)
    let change: dict<unknown> = Js.Dict.empty()

    // Update progress tracking from checkpoint data
    state.progressBlockByChain->Js.Dict.set(
      checkpointChainIds->Array.getUnsafe(i)->Int.toString,
      checkpointBlockNumbers->Array.getUnsafe(i),
    )

    // Add checkpoint metadata
    change->Js.Dict.set("block", checkpointBlockNumbers->Array.getUnsafe(i)->Utils.magic)
    switch checkpointBlockHashes->Array.getUnsafe(i)->Js.Null.toOption {
    | Some(hash) => change->Js.Dict.set("blockHash", hash->Utils.magic)
    | None => () // Skip blockHash when null
    }
    change->Js.Dict.set("chainId", checkpointChainIds->Array.getUnsafe(i)->Utils.magic)
    change->Js.Dict.set(
      "eventsProcessed",
      checkpointEventsProcessed->Array.getUnsafe(i)->Utils.magic,
    )

    // Add entity changes for this checkpoint
    let checkpointKey = checkpointId->BigInt.toString
    switch changesByCheckpoint->Js.Dict.get(checkpointKey) {
    | Some(entityChanges) =>
      entityChanges
      ->Js.Dict.entries
      ->Array.forEach(((entityName, {sets, deleted})) => {
        // Transform dynamic_contract_registry to addresses with simplified structure
        if entityName === InternalTable.DynamicContractRegistry.name {
          let entityObj: dict<unknown> = Js.Dict.empty()
          if sets->Array.length > 0 {
            // Transform sets to simplified {address, contract} objects
            let simplifiedSets = sets->Array.map(entity => {
              let dc = entity->Utils.magic->castFromDcRegistry
              {"address": dc.contractAddress, "contract": dc.contractName}
            })
            entityObj->Js.Dict.set("sets", simplifiedSets->Utils.magic)
          }
          // Note: deleted is not relevant for addresses since we use address string directly
          change->Js.Dict.set("addresses", entityObj->Utils.magic)
        } else {
          let entityObj: dict<unknown> = Js.Dict.empty()
          if sets->Array.length > 0 {
            entityObj->Js.Dict.set("sets", sets->Utils.magic)
          }
          if deleted->Array.length > 0 {
            entityObj->Js.Dict.set("deleted", deleted->Utils.magic)
          }
          change->Js.Dict.set(entityName, entityObj->Utils.magic)
        }
      })
    | None => ()
    }

    state.processChanges->Array.push(change->Utils.magic)->ignore
  }
}

let makeInitialState = (
  ~config: Config.t,
  ~processConfigChains: Js.Dict.t<chainConfig>,
  ~dynamicContractsByChain: dict<array<Internal.indexingContract>>,
): Persistence.initialState => {
  let chainKeys = processConfigChains->Js.Dict.keys
  let chains = chainKeys->Array.map(chainIdStr => {
    let chainId = chainIdStr->Int.fromString->Option.getWithDefault(0)
    let chain = ChainMap.Chain.makeUnsafe(~chainId)

    if !(config.chainMap->ChainMap.has(chain)) {
      Js.Exn.raiseError(`Chain ${chainIdStr} is not configured in config.yaml`)
    }

    let processChainConfig = processConfigChains->Js.Dict.unsafeGet(chainIdStr)
    let dynamicContracts =
      dynamicContractsByChain
      ->Js.Dict.get(chainIdStr)
      ->Option.getWithDefault([])
    {
      Persistence.id: chainId,
      startBlock: processChainConfig.startBlock,
      endBlock: Some(processChainConfig.endBlock),
      sourceBlockNumber: processChainConfig.endBlock,
      maxReorgDepth: 0, // No reorg support in test indexer
      progressBlockNumber: -1,
      numEventsProcessed: 0.,
      firstEventBlockNumber: None,
      timestampCaughtUpToHeadOrEndblock: None,
      dynamicContracts,
    }
  })

  {
    cleanRun: true,
    cache: Js.Dict.empty(),
    chains,
    checkpointId: InternalTable.Checkpoints.initialCheckpointId,
    reorgCheckpoints: [],
  }
}

type rawChainConfig = {
  startBlock: option<int>,
  endBlock: option<int>,
  simulate: option<array<Js.Json.t>>,
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
  ~simulateItems: array<Js.Json.t>,
  ~config: Config.t,
  ~startBlock: int,
): int => {
  let maxBlock = ref(startBlock)
  simulateItems->Array.forEach(rawJson => {
    let blockJson: option<Js.Json.t> =
      (rawJson->(Utils.magic: Js.Json.t => {..}))["block"]
      ->(Utils.magic: 'a => Js.Nullable.t<Js.Json.t>)
      ->Js.Nullable.toOption
    switch blockJson {
    | Some(bj) =>
      let blockDict = bj->(Utils.magic: Js.Json.t => Js.Dict.t<Js.Json.t>)
      let n: option<int> =
        blockDict
        ->Js.Dict.get(config.ecosystem.blockNumberName)
        ->Option.flatMap(v =>
          v->(Utils.magic: Js.Json.t => Js.Nullable.t<int>)->Js.Nullable.toOption
        )
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
  | None => Js.Exn.raiseError(`Invalid chain ID "${chainIdStr}": expected a numeric chain ID`)
  }
  let chain = ChainMap.Chain.makeUnsafe(~chainId)
  if !(config.chainMap->ChainMap.has(chain)) {
    Js.Exn.raiseError(`Chain ${chainIdStr} is not configured in config.yaml`)
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
  | Some(eb) => eb
  | None if rawChainConfig.simulate->Option.isSome =>
    getSimulateEndBlock(~simulateItems=rawChainConfig.simulate->Option.getExn, ~config, ~startBlock)
  | None =>
    Js.Exn.raiseError(`endBlock is required for chain ${chainIdStr} when simulate is not provided`)
  }

  if startBlock < configChain.startBlock {
    Js.Exn.raiseError(
      `Invalid block range for chain ${chainIdStr}: startBlock (${startBlock->Int.toString}) is less than config.startBlock (${configChain.startBlock->Int.toString}). ` ++
      `Either use startBlock >= ${configChain.startBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  }

  switch configChain.endBlock {
  | Some(configEndBlock) if endBlock > configEndBlock =>
    Js.Exn.raiseError(
      `Invalid block range for chain ${chainIdStr}: endBlock (${endBlock->Int.toString}) exceeds config.endBlock (${configEndBlock->Int.toString}). ` ++
      `Either use endBlock <= ${configEndBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  | _ => ()
  }

  switch progressBlock {
  | Some(prevEndBlock) if startBlock <= prevEndBlock =>
    Js.Exn.raiseError(
      `Invalid block range for chain ${chainIdStr}: startBlock (${startBlock->Int.toString}) must be greater than previously processed endBlock (${prevEndBlock->Int.toString}). ` ++
      `Either use startBlock > ${prevEndBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  | _ => ()
  }

  {startBlock, endBlock}
}

// Entity operations for direct manipulation outside of handlers
let getEntityFromState = (
  ~state: testIndexerState,
  ~entityConfig: Internal.entityConfig,
  ~entityId: string,
  ~methodName: string,
): option<Internal.entity> => {
  if state.processInProgress {
    Js.Exn.raiseError(
      `Cannot call ${entityConfig.name}.${methodName}() while indexer.process() is running. ` ++ "Wait for process() to complete before accessing entities directly.",
    )
  }
  let entityDict =
    state.entities->Js.Dict.get(entityConfig.name)->Option.getWithDefault(Js.Dict.empty())
  entityDict->Js.Dict.get(entityId)
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
      Js.Exn.raiseError(msg)
    }
  }
}

let makeEntitySet = (~state: testIndexerState, ~entityConfig: Internal.entityConfig): (
  Internal.entity => unit
) => {
  entity => {
    if state.processInProgress {
      Js.Exn.raiseError(
        `Cannot call ${entityConfig.name}.set() while indexer.process() is running. ` ++ "Wait for process() to complete before modifying entities directly.",
      )
    }
    let entityDict = switch state.entities->Js.Dict.get(entityConfig.name) {
    | Some(dict) => dict
    | None =>
      let dict = Js.Dict.empty()
      state.entities->Js.Dict.set(entityConfig.name, dict)
      dict
    }
    entityDict->Js.Dict.set(entity.id, entity)
  }
}

let makeEntityGetAll = (~state: testIndexerState, ~entityConfig: Internal.entityConfig): (
  unit => promise<array<Internal.entity>>
) => {
  () => {
    if state.processInProgress {
      Js.Exn.raiseError(
        `Cannot call ${entityConfig.name}.getAll() while indexer.process() is running. ` ++ "Wait for process() to complete before accessing entities directly.",
      )
    }
    let entityDict =
      state.entities->Js.Dict.get(entityConfig.name)->Option.getWithDefault(Js.Dict.empty())
    Promise.resolve(entityDict->Js.Dict.values)
  }
}

type entityOperations = {
  get: string => promise<option<Internal.entity>>,
  getAll: unit => promise<array<Internal.entity>>,
  getOrThrow: (string, ~message: string=?) => promise<Internal.entity>,
  set: Internal.entity => unit,
}

type workerData = {
  chainId: int,
  startBlock: int,
  endBlock: int,
  simulate: option<array<Js.Json.t>>,
  initialState: Persistence.initialState,
}

let makeCreateTestIndexer = (
  ~config: Config.t,
  ~workerPath: string,
  ~allEntities: array<Internal.entityConfig>,
): (unit => t<'processConfig>) => {
  () => {
    let entities = Js.Dict.empty()
    let entityConfigs = Js.Dict.empty()
    allEntities->Array.forEach(entityConfig => {
      entities->Js.Dict.set(entityConfig.name, Js.Dict.empty())
      entityConfigs->Js.Dict.set(entityConfig.name, entityConfig)
    })
    let state = {
      processInProgress: false,
      progressBlockByChain: Js.Dict.empty(),
      entities,
      entityConfigs,
      processChanges: [],
    }

    // Build entity operations for each user entity
    let entityOpsDict: Js.Dict.t<entityOperations> = Js.Dict.empty()
    allEntities->Array.forEach(entityConfig => {
      // Only create ops for user entities (not internal tables like dynamic_contract_registry)
      if entityConfig.name !== InternalTable.DynamicContractRegistry.name {
        entityOpsDict->Js.Dict.set(
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
      chainIds->Js.Array2.push(chainConfig.id)->ignore

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
      ->Utils.Object.definePropertyWithValue("isLive", {enumerable: true, value: false})
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
                Js.Exn.raiseError(
                  `Cannot access ${contract.name}.addresses while indexer.process() is running. ` ++ "Wait for process() to complete before reading contract addresses.",
                )
              }
              // Start with static config addresses
              let addresses = contract.addresses->Array.copy
              // Add accumulated dynamic contract addresses
              switch state.entities->Js.Dict.get(InternalTable.DynamicContractRegistry.name) {
              | Some(dcDict) =>
                dcDict
                ->Js.Dict.values
                ->Array.forEach(
                  entity => {
                    let dc = entity->castFromDcRegistry
                    if dc.contractName === contract.name && dc.chainId === chainConfig.id {
                      addresses->Array.push(dc.contractAddress)->ignore
                    }
                  },
                )
              | None => ()
              }
              addresses
            },
          },
        )
        ->ignore

        chainObj
        ->Utils.Object.definePropertyWithValue(
          contract.name,
          {enumerable: true, value: contractObj},
        )
        ->ignore
      })

      chains
      ->Utils.Object.definePropertyWithValue(chainIdStr, {enumerable: true, value: chainObj})
      ->ignore

      if chainConfig.name !== chainIdStr {
        chains
        ->Utils.Object.definePropertyWithValue(
          chainConfig.name,
          {enumerable: false, value: chainObj},
        )
        ->ignore
      }
    })

    // Build the result object with process + entity operations + chain info
    let result: Js.Dict.t<unknown> = Js.Dict.empty()
    result->Js.Dict.set("chainIds", chainIds->(Utils.magic: array<int> => unknown))
    result->Js.Dict.set("chains", chains->(Utils.magic: {..} => unknown))
    entityOpsDict
    ->Js.Dict.entries
    ->Array.forEach(((name, ops)) => {
      result->Js.Dict.set(name, ops->(Utils.magic: entityOperations => unknown))
    })

    result->Js.Dict.set(
      "process",
      (
        processConfig => {
          // Check if already processing
          if state.processInProgress {
            Js.Exn.raiseError(
              "createTestIndexer process is already running. Only one process call is allowed at a time",
            )
          }

          // Parse and validate processConfig
          let parsedConfig = try processConfig->S.parseOrThrow(processConfigSchema) catch {
          | S.Raised(exn) =>
            Js.Exn.raiseError(
              `Invalid processConfig: ${exn->Utils.prettifyExn->(Utils.magic: exn => string)}`,
            )
          }
          let rawChains = parsedConfig["chains"]
          let chainKeys = rawChains->Js.Dict.keys

          if chainKeys->Array.length === 0 {
            Js.Exn.raiseError("createTestIndexer requires at least one chain to be defined")
          }

          // Sort chain keys by chain ID for deterministic ordering
          let sortedChainKeys =
            chainKeys
            ->Array.copy
            ->Js.Array2.sortInPlaceWith((a, b) => {
              let aId = a->Int.fromString->Option.getWithDefault(0)
              let bId = b->Int.fromString->Option.getWithDefault(0)
              aId - bId
            })

          // Parse and validate all chain configs upfront before starting any workers
          let chainEntries = sortedChainKeys->Array.map(chainIdStr => {
            let rawChainConfig = rawChains->Js.Dict.unsafeGet(chainIdStr)
            let chainId = switch chainIdStr->Int.fromString {
            | Some(id) => id
            | None =>
              Js.Exn.raiseError(`Invalid chain ID "${chainIdStr}": expected a numeric chain ID`)
            }
            let processChainConfig = parseBlockRange(
              ~chainIdStr,
              ~config,
              ~rawChainConfig,
              ~progressBlock=state.progressBlockByChain->Js.Dict.get(chainIdStr),
            )
            (chainIdStr, chainId, rawChainConfig, processChainConfig)
          })

          // Reset processChanges for this run
          state.processChanges = []

          let runChainWorker = ((
            chainIdStr,
            chainId,
            rawChainConfig: rawChainConfig,
            processChainConfig,
          )) => {
            // Build initialState from resolved block range
            let chains: Js.Dict.t<chainConfig> = Js.Dict.empty()
            chains->Js.Dict.set(chainIdStr, processChainConfig)

            // Extract dynamic contracts from state.entities for each chain
            let dynamicContractsByChain: dict<array<Internal.indexingContract>> = Js.Dict.empty()
            switch state.entities->Js.Dict.get(InternalTable.DynamicContractRegistry.name) {
            | Some(dcDict) =>
              dcDict
              ->Js.Dict.values
              ->Array.forEach(entity => {
                let dc = entity->castFromDcRegistry
                let dcChainIdStr = dc.chainId->Int.toString
                let contracts = switch dynamicContractsByChain->Js.Dict.get(dcChainIdStr) {
                | Some(arr) => arr
                | None =>
                  let arr = []
                  dynamicContractsByChain->Js.Dict.set(dcChainIdStr, arr)
                  arr
                }
                contracts->Array.push(dc->toIndexingContract)->ignore
              })
            | None => ()
            }

            let initialState = makeInitialState(
              ~config,
              ~processConfigChains=chains,
              ~dynamicContractsByChain,
            )

            Promise.make((resolve, reject) => {
              let workerData: workerData = {
                chainId,
                startBlock: processChainConfig.startBlock,
                endBlock: processChainConfig.endBlock,
                simulate: rawChainConfig.simulate,
                initialState,
              }
              let worker = try {
                NodeJs.WorkerThreads.makeWorker(
                  workerPath,
                  {
                    workerData: workerData->(Utils.magic: workerData => Js.Json.t),
                  },
                )
              } catch {
              | exn =>
                reject(exn->Utils.magic)
                raise(exn)
              }

              // Handle messages from worker
              worker->NodeJs.WorkerThreads.onMessage((
                msg: TestIndexerProxyStorage.workerMessage,
              ) => {
                let respond = data =>
                  worker->NodeJs.WorkerThreads.workerPostMessage(
                    {
                      TestIndexerProxyStorage.id: msg.id,
                      payload: TestIndexerProxyStorage.Response({data: data}),
                    }->Utils.magic,
                  )

                switch msg.payload {
                | LoadByIds({tableName, ids}) => state->handleLoadByIds(~tableName, ~ids)->respond

                | LoadByField({tableName, fieldName, fieldValue, operator}) =>
                  state
                  ->handleLoadByField(~tableName, ~fieldName, ~fieldValue, ~operator)
                  ->respond

                | WriteBatch({
                    updatedEntities,
                    checkpointIds,
                    checkpointChainIds,
                    checkpointBlockNumbers,
                    checkpointBlockHashes,
                    checkpointEventsProcessed,
                  }) =>
                  state->handleWriteBatch(
                    ~updatedEntities,
                    ~checkpointIds,
                    ~checkpointChainIds,
                    ~checkpointBlockNumbers,
                    ~checkpointBlockHashes,
                    ~checkpointEventsProcessed,
                  )
                  Js.Json.null->respond
                }
              })

              worker->NodeJs.WorkerThreads.onError(err => {
                worker->NodeJs.WorkerThreads.terminate->ignore
                reject(err)
              })

              worker->NodeJs.WorkerThreads.onExit(code => {
                if code !== 0 {
                  reject(Utils.Error.make(`Worker exited with code ${code->Int.toString}`))
                } else {
                  resolve()
                }
              })
            })
          }

          // Set flag before starting workers
          state.processInProgress = true

          // Run worker threads sequentially, one chain at a time
          let rec runChains = idx => {
            if idx >= chainEntries->Array.length {
              state.processInProgress = false
              Promise.resolve({changes: state.processChanges})
            } else {
              runChainWorker(chainEntries->Array.getUnsafe(idx))->Promise.then(_ =>
                runChains(idx + 1)
              )
            }
          }

          runChains(0)->Promise.catch(err => {
            state.processInProgress = false
            Promise.reject(err->(Utils.magic: exn => exn))
          })
        }
      )->(Utils.magic: ('a => promise<processResult>) => unknown),
    )

    result->(Utils.magic: Js.Dict.t<unknown> => t<'processConfig>)
  }
}

let initTestWorker = (~makeGeneratedConfig: unit => Config.t) => {
  if NodeJs.WorkerThreads.isMainThread {
    Js.Exn.raiseError("initTestWorker must be called from a worker thread")
  }

  let parentPort = switch NodeJs.WorkerThreads.parentPort->Js.Nullable.toOption {
  | Some(port) => port
  | None => Js.Exn.raiseError("initTestWorker: No parent port available")
  }

  let workerData: option<workerData> = NodeJs.WorkerThreads.workerData->Js.Nullable.toOption
  switch workerData {
  | Some({chainId, startBlock, endBlock, simulate, initialState}) =>
    let chainIdStr = chainId->Int.toString

    // Build processConfig JSON for SimulateItems.patchConfig
    let resolvedChainDict: Js.Dict.t<unknown> = Js.Dict.empty()
    resolvedChainDict->Js.Dict.set("startBlock", startBlock->(Utils.magic: int => unknown))
    resolvedChainDict->Js.Dict.set("endBlock", endBlock->(Utils.magic: int => unknown))
    switch simulate {
    | Some(s) =>
      resolvedChainDict->Js.Dict.set("simulate", s->(Utils.magic: array<Js.Json.t> => unknown))
    | None => ()
    }
    let resolvedChainsDict: Js.Dict.t<unknown> = Js.Dict.empty()
    resolvedChainsDict->Js.Dict.set(
      chainIdStr,
      resolvedChainDict->(Utils.magic: Js.Dict.t<unknown> => unknown),
    )
    let processConfig =
      {"chains": resolvedChainsDict}->(Utils.magic: {"chains": Js.Dict.t<unknown>} => Js.Json.t)

    // Create proxy storage that communicates with main thread
    let proxy = TestIndexerProxyStorage.make(~parentPort, ~initialState)
    let storage = TestIndexerProxyStorage.makeStorage(proxy)
    let config = makeGeneratedConfig()
    let persistence = Persistence.make(
      ~userEntities=config.userEntities,
      ~allEnums=config.allEnums,
      ~storage,
    )

    // Silence logs by default in test mode unless LOG_LEVEL is explicitly set
    switch Env.userLogLevel {
    | None => Logging.setLogLevel(#silent)
    | Some(_) => ()
    }

    let patchConfig = (config, _registrations) => SimulateItems.patchConfig(~config, ~processConfig)
    Main.start(~makeGeneratedConfig, ~persistence, ~isTest=true, ~patchConfig)->ignore
  | None =>
    Logging.error("TestIndexerWorker: No worker data provided")
    NodeJs.process->NodeJs.exitWithCode(Failure)
  }
}
