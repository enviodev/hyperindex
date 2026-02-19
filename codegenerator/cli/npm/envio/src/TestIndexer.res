open Belt

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
): JSON.t => {
  let entityDict =
    state.entities
    ->Dict.get(tableName)
    ->Option.getWithDefault(
      Dict.make(),

      // Check if already processing

      // Validate chains

      // Validate block ranges for each chain

      // Reset processChanges for this run

      // Extract dynamic contracts from state.entities for each chain

      // Create initialState from processConfig chains

      // Include initialState in workerData

      // Set flag only after worker is successfully created

      // Handle messages from worker

      // Update progressBlockByChain with processed endBlock for each chain

      // Worker exited successfully (SuccessExit was dispatched in GlobalState)
    )
  let entityConfig = state.entityConfigs->Dict.getUnsafe(tableName)
  let results = []
  ids->Array.forEach(id => {
    switch entityDict->Dict.get(id) {
    | Some(entity) =>
      // Serialize entity back to JSON for worker thread
      let jsonEntity = entity->S.reverseConvertToJsonOrThrow(entityConfig.schema)
      results->Array.push(jsonEntity)->ignore
    | None => ()
    }
  })
  results->JSON.Encode.array
}

let handleLoadByField = (
  state: testIndexerState,
  ~tableName: string,
  ~fieldName: string,
  ~fieldValue: JSON.t,
  ~operator: Persistence.operator,
): JSON.t => {
  let entityDict = state.entities->Dict.get(tableName)->Option.getWithDefault(Dict.make())
  let entityConfig = state.entityConfigs->Dict.getUnsafe(tableName)
  let results = []

  // Get the field schema from the entity's table to properly parse the JSON field value
  let fieldSchema = switch entityConfig.table->Table.getFieldByName(fieldName) {
  | Some(Table.Field({fieldSchema})) => fieldSchema
  | _ => JsError.throwWithMessage(`Field ${fieldName} not found in entity ${tableName}`)
  }

  // Parse JSON field value to typed value using the field's schema
  let parsedFieldValue = fieldValue->S.convertOrThrow(fieldSchema)->TableIndices.FieldValue.castFrom

  // Compare using TableIndices.FieldValue logic (same approach as InMemoryTable)
  // This properly handles bigint and BigDecimal comparisons
  entityDict
  ->Dict.valuesToArray
  ->Array.forEach(entity => {
    // Cast entity to dict of field values (same approach as InMemoryTable)
    let entityAsDict = entity->(Utils.magic: Internal.entity => dict<TableIndices.FieldValue.t>)
    switch entityAsDict->Dict.get(fieldName) {
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

  results->JSON.Encode.array
}

let handleWriteBatch = (
  state: testIndexerState,
  ~updatedEntities: array<TestIndexerProxyStorage.serializableUpdatedEntity>,
  ~checkpointIds: array<float>,
  ~checkpointChainIds: array<int>,
  ~checkpointBlockNumbers: array<int>,
  ~checkpointBlockHashes: array<Null.t<string>>,
  ~checkpointEventsProcessed: array<int>,
): unit => {
  // Group entity changes by checkpointId
  // checkpointId -> entityName -> entityChange
  let changesByCheckpoint: dict<dict<entityChange>> = Dict.make()

  updatedEntities->Array.forEach(({entityName, updates}) => {
    let entityDict = switch state.entities->Dict.get(entityName) {
    | Some(dict) => dict
    | None =>
      let dict = Dict.make()
      state.entities->Dict.set(entityName, dict)
      dict
    }
    let entityConfig = state.entityConfigs->Dict.getUnsafe(entityName)

    updates->Array.forEach(update => {
      // Helper to process a single change (Set or Delete)
      let processChange = (change: TestIndexerProxyStorage.serializableChange) => {
        switch change {
        | Set({entityId, entity, checkpointId}) =>
          // Parse entity immediately to store decoded values for proper comparisons
          // (bigint/BigDecimal need actual values, not JSON strings)
          let parsedEntity = entity->S.parseOrThrow(entityConfig.schema)

          // Update entities dict with parsed entity for load operations
          entityDict->Dict.set(entityId, parsedEntity)

          // Track change by checkpoint
          let checkpointKey = checkpointId->Float.toString
          let entityChanges = switch changesByCheckpoint->Dict.get(checkpointKey) {
          | Some(changes) => changes
          | None =>
            let changes = Dict.make()
            changesByCheckpoint->Dict.set(checkpointKey, changes)
            changes
          }
          let entityChange = switch entityChanges->Dict.get(entityName) {
          | Some(change) => change
          | None =>
            let change = {sets: [], deleted: []}
            entityChanges->Dict.set(entityName, change)
            change
          }
          entityChange.sets->Array.push(parsedEntity->Utils.magic)->ignore

        | Delete({entityId, checkpointId}) =>
          // Update entities dict for load operations
          Dict.delete(entityDict->Obj.magic, entityId)

          // Track change by checkpoint
          let checkpointKey = checkpointId->Float.toString
          let entityChanges = switch changesByCheckpoint->Dict.get(checkpointKey) {
          | Some(changes) => changes
          | None =>
            let changes = Dict.make()
            changesByCheckpoint->Dict.set(checkpointKey, changes)
            changes
          }
          let entityChange = switch entityChanges->Dict.get(entityName) {
          | Some(change) => change
          | None =>
            let change = {sets: [], deleted: []}
            entityChanges->Dict.set(entityName, change)
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
    let change: dict<unknown> = Dict.make()

    // Add checkpoint metadata
    change->Dict.set("block", checkpointBlockNumbers->Array.getUnsafe(i)->Utils.magic)
    switch checkpointBlockHashes->Array.getUnsafe(i)->Null.toOption {
    | Some(hash) => change->Dict.set("blockHash", hash->Utils.magic)
    | None => () // Skip blockHash when null
    }
    change->Dict.set("chainId", checkpointChainIds->Array.getUnsafe(i)->Utils.magic)
    change->Dict.set("eventsProcessed", checkpointEventsProcessed->Array.getUnsafe(i)->Utils.magic)

    // Add entity changes for this checkpoint
    let checkpointKey = checkpointId->Float.toString
    switch changesByCheckpoint->Dict.get(checkpointKey) {
    | Some(entityChanges) =>
      entityChanges
      ->Dict.toArray
      ->Array.forEach(((entityName, {sets, deleted})) => {
        // Transform dynamic_contract_registry to addresses with simplified structure
        if entityName === InternalTable.DynamicContractRegistry.name {
          let entityObj: dict<unknown> = Dict.make()
          if sets->Array.length > 0 {
            // Transform sets to simplified {address, contract} objects
            let simplifiedSets = sets->Array.map(entity => {
              let dc = entity->Utils.magic->castFromDcRegistry
              {"address": dc.contractAddress, "contract": dc.contractName}
            })
            entityObj->Dict.set("sets", simplifiedSets->Utils.magic)
          }
          // Note: deleted is not relevant for addresses since we use address string directly
          change->Dict.set("addresses", entityObj->Utils.magic)
        } else {
          let entityObj: dict<unknown> = Dict.make()
          if sets->Array.length > 0 {
            entityObj->Dict.set("sets", sets->Utils.magic)
          }
          if deleted->Array.length > 0 {
            entityObj->Dict.set("deleted", deleted->Utils.magic)
          }
          change->Dict.set(entityName, entityObj->Utils.magic)
        }
      })
    | None => ()
    }

    state.processChanges->Array.push(change->Utils.magic)->ignore
  }
}

let makeInitialState = (
  ~config: Config.t,
  ~processConfigChains: dict<chainConfig>,
  ~dynamicContractsByChain: dict<array<Internal.indexingContract>>,
): Persistence.initialState => {
  let chainKeys = processConfigChains->Dict.keysToArray
  let chains = chainKeys->Array.map(chainIdStr => {
    let chainId = chainIdStr->Int.fromString->Option.getWithDefault(0)
    let chain = ChainMap.Chain.makeUnsafe(~chainId)

    if !(config.chainMap->ChainMap.has(chain)) {
      JsError.throwWithMessage(`Chain ${chainIdStr} is not configured in config.yaml`)
    }

    let processChainConfig = processConfigChains->Dict.getUnsafe(chainIdStr)
    let dynamicContracts =
      dynamicContractsByChain
      ->Dict.get(chainIdStr)
      ->Option.getWithDefault([])
    {
      Persistence.id: chainId,
      startBlock: processChainConfig.startBlock,
      endBlock: Some(processChainConfig.endBlock),
      sourceBlockNumber: processChainConfig.endBlock,
      maxReorgDepth: 0, // No reorg support in test indexer
      progressBlockNumber: -1,
      numEventsProcessed: 0,
      firstEventBlockNumber: None,
      timestampCaughtUpToHeadOrEndblock: None,
      dynamicContracts,
    }
  })

  {
    cleanRun: true,
    cache: Dict.make(),
    chains,
    checkpointId: InternalTable.Checkpoints.initialCheckpointId,
    reorgCheckpoints: [],
  }
}

let validateBlockRange = (
  ~chainId: string,
  ~configChain: Config.chain,
  ~processChainConfig: chainConfig,
  ~progressBlock: option<int>,
) => {
  // Check startBlock >= config.startBlock
  if processChainConfig.startBlock < configChain.startBlock {
    JsError.throwWithMessage(
      `Invalid block range for chain ${chainId}: startBlock (${processChainConfig.startBlock->Int.toString}) is less than config.startBlock (${configChain.startBlock->Int.toString}). ` ++
      `Either use startBlock >= ${configChain.startBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  }

  // Check endBlock <= config.endBlock (if defined)
  switch configChain.endBlock {
  | Some(configEndBlock) if processChainConfig.endBlock > configEndBlock =>
    JsError.throwWithMessage(
      `Invalid block range for chain ${chainId}: endBlock (${processChainConfig.endBlock->Int.toString}) exceeds config.endBlock (${configEndBlock->Int.toString}). ` ++
      `Either use endBlock <= ${configEndBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  | _ => ()
  }

  // Check startBlock > progressBlock
  switch progressBlock {
  | Some(prevEndBlock) if processChainConfig.startBlock <= prevEndBlock =>
    JsError.throwWithMessage(
      `Invalid block range for chain ${chainId}: startBlock (${processChainConfig.startBlock->Int.toString}) must be greater than previously processed endBlock (${prevEndBlock->Int.toString}). ` ++
      `Either use startBlock > ${prevEndBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  | _ => ()
  }
}

// Entity operations for direct manipulation outside of handlers
let makeEntityGet = (~state: testIndexerState, ~entityConfig: Internal.entityConfig): (
  string => promise<option<Internal.entity>>
) => {
  entityId => {
    if state.processInProgress {
      JsError.throwWithMessage(
        `Cannot call ${entityConfig.name}.get() while indexer.process() is running. ` ++ "Wait for process() to complete before accessing entities directly.",
      )
    }
    let entityDict = state.entities->Dict.get(entityConfig.name)->Option.getWithDefault(Dict.make())
    Promise_.resolve(entityDict->Dict.get(entityId))
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
    entityDict->Dict.set(entity.id, entity)
  }
}

type entityOps = {
  get: string => promise<option<Internal.entity>>,
  set: Internal.entity => unit,
}

let makeCreateTestIndexer = (
  ~config: Config.t,
  ~workerPath: string,
  ~allEntities: array<Internal.entityConfig>,
): (unit => t<'processConfig>) => {
  () => {
    let entities = Dict.make()
    let entityConfigs = Dict.make()
    allEntities->Array.forEach(entityConfig => {
      entities->Dict.set(entityConfig.name, Dict.make())
      entityConfigs->Dict.set(entityConfig.name, entityConfig)
    })
    let state = {
      processInProgress: false,
      progressBlockByChain: Dict.make(),
      entities,
      entityConfigs,
      processChanges: [],
    }

    // Build entity operations for each user entity
    let entityOpsDict: dict<entityOps> = Dict.make()
    allEntities->Array.forEach(entityConfig => {
      // Only create ops for user entities (not internal tables like dynamic_contract_registry)
      if entityConfig.name !== InternalTable.DynamicContractRegistry.name {
        entityOpsDict->Dict.set(
          entityConfig.name,
          {
            get: makeEntityGet(~state, ~entityConfig),
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
                JsError.throwWithMessage(
                  `Cannot access ${contract.name}.addresses while indexer.process() is running. ` ++ "Wait for process() to complete before reading contract addresses.",
                )
              }
              // Start with static config addresses
              let addresses = contract.addresses->Array.copy
              // Add accumulated dynamic contract addresses
              switch state.entities->Dict.get(InternalTable.DynamicContractRegistry.name) {
              | Some(dcDict) =>
                dcDict
                ->Dict.valuesToArray
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
    let result: dict<unknown> = Dict.make()
    result->Dict.set("chainIds", chainIds->(Utils.magic: array<int> => unknown))
    result->Dict.set("chains", chains->(Utils.magic: {..} => unknown))
    entityOpsDict
    ->Dict.toArray
    ->Array.forEach(((name, ops)) => {
      result->Dict.set(name, ops->(Utils.magic: entityOps => unknown))
    })

    result->Dict.set(
      "process",
      (
        processConfig => {
          if state.processInProgress {
            JsError.throwWithMessage(
              "createTestIndexer process is already running. Only one process call is allowed at a time",
            )
          }

          let chains: dict<chainConfig> = (processConfig->Utils.magic)["chains"]->Utils.magic
          let chainKeys = chains->Dict.keysToArray

          switch chainKeys->Array.length {
          | 0 =>
            JsError.throwWithMessage("createTestIndexer requires exactly one chain to be defined")
          | 1 => ()
          | n =>
            JsError.throwWithMessage(
              `createTestIndexer does not support processing multiple chains at once. Found ${n->Int.toString} chains defined`,
            )
          }

          chainKeys->Array.forEach(chainIdStr => {
            let chainId = chainIdStr->Int.fromString->Option.getWithDefault(0)
            let chain = ChainMap.Chain.makeUnsafe(~chainId)
            let configChain = config.chainMap->ChainMap.get(chain)
            let processChainConfig = chains->Dict.getUnsafe(chainIdStr)
            let progressBlock = state.progressBlockByChain->Dict.get(chainIdStr)

            validateBlockRange(
              ~chainId=chainIdStr,
              ~configChain,
              ~processChainConfig,
              ~progressBlock,
            )
          })

          state.processChanges = []

          let dynamicContractsByChain: dict<array<Internal.indexingContract>> = Dict.make()
          switch state.entities->Dict.get(InternalTable.DynamicContractRegistry.name) {
          | Some(dcDict) =>
            dcDict
            ->Dict.valuesToArray
            ->Array.forEach(entity => {
              let dc = entity->castFromDcRegistry
              let chainIdStr = dc.chainId->Int.toString
              let contracts = switch dynamicContractsByChain->Dict.get(chainIdStr) {
              | Some(arr) => arr
              | None =>
                let arr = []
                dynamicContractsByChain->Dict.set(chainIdStr, arr)
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

          Promise_.make((resolve, reject) => {
            let workerDataObj = {
              "processConfig": processConfig->Utils.magic->Js.Json.serializeExn->JSON.parseOrThrow,
              "initialState": initialState->Utils.magic,
            }
            let workerData = workerDataObj->Js.Json.serializeExn->JSON.parseOrThrow
            let worker = try {
              NodeJs.WorkerThreads.makeWorker(
                workerPath,
                {
                  workerData: workerData,
                },
              )
            } catch {
            | exn =>
              reject(exn->Utils.magic)
              throw(exn)
            }

            state.processInProgress = true

            worker->NodeJs.WorkerThreads.onMessage((msg: TestIndexerProxyStorage.workerMessage) => {
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
                state->handleLoadByField(~tableName, ~fieldName, ~fieldValue, ~operator)->respond

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
                JSON.Encode.null->respond
              }
            })

            worker->NodeJs.WorkerThreads.onError(err => {
              state.processInProgress = false
              worker->NodeJs.WorkerThreads.terminate->ignore
              reject(err)
            })

            worker->NodeJs.WorkerThreads.onExit(code => {
              state.processInProgress = false
              if code !== 0 {
                reject(Utils.Error.make(`Worker exited with code ${code->Int.toString}`))
              } else {
                chainKeys->Array.forEach(
                  chainIdStr => {
                    let processChainConfig = chains->Dict.getUnsafe(chainIdStr)
                    state.progressBlockByChain->Dict.set(chainIdStr, processChainConfig.endBlock)
                  },
                )

                resolve({
                  changes: state.processChanges,
                })
              }
            })
          })
        }
      )->(Utils.magic: ('a => promise<processResult>) => unknown),
    )

    result->(Utils.magic: dict<unknown> => t<'processConfig>)
  }
}

type workerData = {
  processConfig: JSON.t,
  initialState: Persistence.initialState,
}

let initTestWorker = (~makeGeneratedConfig: unit => Config.t) => {
  if NodeJs.WorkerThreads.isMainThread {
    JsError.throwWithMessage("initTestWorker must be called from a worker thread")
  }

  let parentPort = switch NodeJs.WorkerThreads.parentPort->Nullable.toOption {
  | Some(port) => port
  | None => JsError.throwWithMessage("initTestWorker: No parent port available")
  }

  let workerData: option<workerData> = NodeJs.WorkerThreads.workerData->Nullable.toOption
  switch workerData {
  | Some({initialState}) =>
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

    Main.start(~makeGeneratedConfig, ~persistence, ~isTest=true)->ignore
  | None =>
    Logging.error("TestIndexerWorker: No worker data provided")
    NodeJs.process->NodeJs.exitWithCode(Failure)
  }
}
