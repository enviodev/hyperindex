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
  ~checkpointIds: array<float>,
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
          let checkpointKey = checkpointId->Float.toString
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
          let checkpointKey = checkpointId->Float.toString
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
    let checkpointKey = checkpointId->Float.toString
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
            let simplifiedSets =
              sets->Array.map(entity => {
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
      numEventsProcessed: 0,
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

let validateBlockRange = (
  ~chainId: string,
  ~configChain: Config.chain,
  ~processChainConfig: chainConfig,
  ~progressBlock: option<int>,
) => {
  // Check startBlock >= config.startBlock
  if processChainConfig.startBlock < configChain.startBlock {
    Js.Exn.raiseError(
      `Invalid block range for chain ${chainId}: startBlock (${processChainConfig.startBlock->Int.toString}) is less than config.startBlock (${configChain.startBlock->Int.toString}). ` ++
      `Either use startBlock >= ${configChain.startBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  }

  // Check endBlock <= config.endBlock (if defined)
  switch configChain.endBlock {
  | Some(configEndBlock) if processChainConfig.endBlock > configEndBlock =>
    Js.Exn.raiseError(
      `Invalid block range for chain ${chainId}: endBlock (${processChainConfig.endBlock->Int.toString}) exceeds config.endBlock (${configEndBlock->Int.toString}). ` ++
      `Either use endBlock <= ${configEndBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  | _ => ()
  }

  // Check startBlock > progressBlock
  switch progressBlock {
  | Some(prevEndBlock) if processChainConfig.startBlock <= prevEndBlock =>
    Js.Exn.raiseError(
      `Invalid block range for chain ${chainId}: startBlock (${processChainConfig.startBlock->Int.toString}) must be greater than previously processed endBlock (${prevEndBlock->Int.toString}). ` ++
      `Either use startBlock > ${prevEndBlock->Int.toString} or create a new test indexer with createTestIndexer().`,
    )
  | _ => ()
  }
}

// Entity operations for direct manipulation outside of handlers
let makeEntityGet = (
  ~state: testIndexerState,
  ~entityConfig: Internal.entityConfig,
): (string => promise<option<Internal.entity>>) => {
  entityId => {
    if state.processInProgress {
      Js.Exn.raiseError(
        `Cannot call ${entityConfig.name}.get() while indexer.process() is running. ` ++
        "Wait for process() to complete before accessing entities directly.",
      )
    }
    let entityDict =
      state.entities->Js.Dict.get(entityConfig.name)->Option.getWithDefault(Js.Dict.empty())
    Promise.resolve(entityDict->Js.Dict.get(entityId))
  }
}

let makeEntitySet = (
  ~state: testIndexerState,
  ~entityConfig: Internal.entityConfig,
): (Internal.entity => unit) => {
  entity => {
    if state.processInProgress {
      Js.Exn.raiseError(
        `Cannot call ${entityConfig.name}.set() while indexer.process() is running. ` ++
        "Wait for process() to complete before modifying entities directly.",
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
    let entityOpsDict: Js.Dict.t<entityOps> = Js.Dict.empty()
    allEntities->Array.forEach(entityConfig => {
      // Only create ops for user entities (not internal tables like dynamic_contract_registry)
      if entityConfig.name !== InternalTable.DynamicContractRegistry.name {
        entityOpsDict->Js.Dict.set(
          entityConfig.name,
          {
            get: makeEntityGet(~state, ~entityConfig),
            set: makeEntitySet(~state, ~entityConfig),
          },
        )
      }
    })

    // Build the result object with process + entity operations
    let result: Js.Dict.t<unknown> = Js.Dict.empty()
    entityOpsDict
    ->Js.Dict.entries
    ->Array.forEach(((name, ops)) => {
      result->Js.Dict.set(name, ops->(Utils.magic: entityOps => unknown))
    })

    result->Js.Dict.set(
      "process",
      (processConfig => {
        // Check if already processing
        if state.processInProgress {
          Js.Exn.raiseError(
            "createTestIndexer process is already running. Only one process call is allowed at a time",
          )
        }

        // Validate chains
        let chains: Js.Dict.t<chainConfig> = (processConfig->Utils.magic)["chains"]->Utils.magic
        let chainKeys = chains->Js.Dict.keys

        switch chainKeys->Array.length {
        | 0 => Js.Exn.raiseError("createTestIndexer requires exactly one chain to be defined")
        | 1 => ()
        | n =>
          Js.Exn.raiseError(
            `createTestIndexer does not support processing multiple chains at once. Found ${n->Int.toString} chains defined`,
          )
        }

        // Validate block ranges for each chain
        chainKeys->Array.forEach(chainIdStr => {
          let chainId = chainIdStr->Int.fromString->Option.getWithDefault(0)
          let chain = ChainMap.Chain.makeUnsafe(~chainId)
          let configChain = config.chainMap->ChainMap.get(chain)
          let processChainConfig = chains->Js.Dict.unsafeGet(chainIdStr)
          let progressBlock = state.progressBlockByChain->Js.Dict.get(chainIdStr)

          validateBlockRange(~chainId=chainIdStr, ~configChain, ~processChainConfig, ~progressBlock)
        })

        // Reset processChanges for this run
        state.processChanges = []

        // Extract dynamic contracts from state.entities for each chain
        let dynamicContractsByChain: dict<array<Internal.indexingContract>> = Js.Dict.empty()
        switch state.entities->Js.Dict.get(InternalTable.DynamicContractRegistry.name) {
        | Some(dcDict) =>
          dcDict
          ->Js.Dict.values
          ->Array.forEach(entity => {
            let dc = entity->castFromDcRegistry
            let chainIdStr = dc.chainId->Int.toString
            let contracts = switch dynamicContractsByChain->Js.Dict.get(chainIdStr) {
            | Some(arr) => arr
            | None =>
              let arr = []
              dynamicContractsByChain->Js.Dict.set(chainIdStr, arr)
              arr
            }
            contracts->Array.push(dc->toIndexingContract)->ignore
          })
        | None => ()
        }

        // Create initialState from processConfig chains
        let initialState = makeInitialState(
          ~config,
          ~processConfigChains=chains,
          ~dynamicContractsByChain,
        )

        Promise.make((resolve, reject) => {
          // Include initialState in workerData
          let workerDataObj = {
            "processConfig": processConfig->Utils.magic->Js.Json.serializeExn->Js.Json.parseExn,
            "initialState": initialState->Utils.magic,
          }
          let workerData = workerDataObj->Js.Json.serializeExn->Js.Json.parseExn
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
            raise(exn)
          }

          // Set flag only after worker is successfully created
          state.processInProgress = true

          // Handle messages from worker
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
              Js.Json.null->respond
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
              // Update progressBlockByChain with processed endBlock for each chain
              chainKeys->Array.forEach(
                chainIdStr => {
                  let processChainConfig = chains->Js.Dict.unsafeGet(chainIdStr)
                  state.progressBlockByChain->Js.Dict.set(chainIdStr, processChainConfig.endBlock)
                },
              )
              // Worker exited successfully (SuccessExit was dispatched in GlobalState)
              resolve({
                changes: state.processChanges,
              })
            }
          })
        })
      })->(Utils.magic: ('a => promise<processResult>) => unknown),
    )

    result->(Utils.magic: Js.Dict.t<unknown> => t<'processConfig>)
  }
}

type workerData = {
  processConfig: Js.Json.t,
  initialState: Persistence.initialState,
}

let initTestWorker = (
  ~makeGeneratedConfig,
  ~makePersistence: (~storage: Persistence.storage) => Persistence.t,
) => {
  if NodeJs.WorkerThreads.isMainThread {
    Js.Exn.raiseError("initTestWorker must be called from a worker thread")
  }

  let parentPort = switch NodeJs.WorkerThreads.parentPort->Js.Nullable.toOption {
  | Some(port) => port
  | None => Js.Exn.raiseError("initTestWorker: No parent port available")
  }

  let workerData: option<workerData> = NodeJs.WorkerThreads.workerData->Js.Nullable.toOption
  switch workerData {
  | Some({initialState}) =>
    // Create proxy storage that communicates with main thread
    let proxy = TestIndexerProxyStorage.make(~parentPort, ~initialState)
    let storage = TestIndexerProxyStorage.makeStorage(proxy)
    let persistence = makePersistence(~storage)

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
