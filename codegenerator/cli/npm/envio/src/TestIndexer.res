open Belt

type chainConfig = {
  startBlock: int,
  endBlock: int,
}

type progress = {
  checkpoints: array<Js.Json.t>,
  changes: dict<array<Js.Json.t>>,
}

type t<'processConfig> = {process: 'processConfig => promise<progress>}

type state = {mutable processInProgress: bool}

// Store for entity data: entityName -> id -> entity (as JSON)
type store = {
  entities: dict<dict<Js.Json.t>>,
  entityConfigs: dict<Internal.entityConfig>,
}

let makeStore = (~allEntities: array<Internal.entityConfig>): store => {
  let entities = Js.Dict.empty()
  let entityConfigs = Js.Dict.empty()
  allEntities->Array.forEach(entityConfig => {
    entities->Js.Dict.set(entityConfig.name, Js.Dict.empty())
    entityConfigs->Js.Dict.set(entityConfig.name, entityConfig)
  })
  {entities, entityConfigs}
}

let handleLoadByIds = (store: store, ~tableName: string, ~ids: array<string>): Js.Json.t => {
  let entityDict = store.entities->Js.Dict.get(tableName)->Option.getWithDefault(Js.Dict.empty())
  let results = []
  ids->Array.forEach(id => {
    switch entityDict->Js.Dict.get(id) {
    | Some(entity) => results->Array.push(entity)->ignore
    | None => ()
    }
  })
  results->Js.Json.array
}

let handleLoadByField = (
  store: store,
  ~tableName: string,
  ~fieldName: string,
  ~fieldValue: Js.Json.t,
  ~operator: Persistence.operator,
): Js.Json.t => {
  let entityDict = store.entities->Js.Dict.get(tableName)->Option.getWithDefault(Js.Dict.empty())
  let results = []

  entityDict
  ->Js.Dict.values
  ->Array.forEach(entity => {
    // Get the field value from the entity
    switch entity->Js.Json.decodeObject {
    | Some(obj) =>
      switch obj->Js.Dict.get(fieldName) {
      | Some(entityFieldValue) => {
          let matches = switch operator {
          | #"=" => entityFieldValue == fieldValue
          | #">" => entityFieldValue > fieldValue
          | #"<" => entityFieldValue < fieldValue
          }
          if matches {
            results->Array.push(entity)->ignore
          }
        }
      | None => ()
      }
    | None => ()
    }
  })

  results->Js.Json.array
}

let handleWriteBatch = (store: store, ~updatedEntities: array<Persistence.updatedEntity>): unit => {
  updatedEntities->Array.forEach(({entityConfig, updates}) => {
    let entityDict = switch store.entities->Js.Dict.get(entityConfig.name) {
    | Some(dict) => dict
    | None =>
      let dict = Js.Dict.empty()
      store.entities->Js.Dict.set(entityConfig.name, dict)
      dict
    }

    updates->Array.forEach(update => {
      switch update.latestChange {
      | Change.Set({entityId, entity}) =>
        let json = entity->S.reverseConvertToJsonOrThrow(entityConfig.schema)
        entityDict->Js.Dict.set(entityId, json)
      | Change.Delete({entityId}) => Js.Dict.unsafeDeleteKey(entityDict->Obj.magic, entityId)
      }
    })
  })
}

let extractChanges = (store: store): dict<array<Js.Json.t>> => {
  let changes = Js.Dict.empty()
  store.entities
  ->Js.Dict.entries
  ->Array.forEach(((entityName, entityDict)) => {
    let values = entityDict->Js.Dict.values
    if values->Array.length > 0 {
      changes->Js.Dict.set(entityName, values)
    }
  })
  changes
}

let makeInitialState = (
  ~config: Config.t,
  ~processConfigChains: Js.Dict.t<chainConfig>,
): Persistence.initialState => {
  let chainKeys = processConfigChains->Js.Dict.keys
  let chains = chainKeys->Array.map(chainIdStr => {
    let chainId = chainIdStr->Int.fromString->Option.getWithDefault(0)
    let chain = ChainMap.Chain.makeUnsafe(~chainId)

    if !(config.chainMap->ChainMap.has(chain)) {
      Js.Exn.raiseError(`Chain ${chainIdStr} is not configured in config.yaml`)
    }

    let processChainConfig = processConfigChains->Js.Dict.unsafeGet(chainIdStr)
    {
      Persistence.id: chainId,
      startBlock: processChainConfig.startBlock,
      endBlock: Some(processChainConfig.endBlock),
      maxReorgDepth: 0, // No reorg support in test indexer
      progressBlockNumber: -1,
      numEventsProcessed: 0,
      firstEventBlockNumber: None,
      timestampCaughtUpToHeadOrEndblock: None,
      dynamicContracts: [],
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

let makeCreateTestIndexer = (
  ~config: Config.t,
  ~workerPath: string,
  ~allEntities: array<Internal.entityConfig>,
): (unit => t<'processConfig>) => {
  () => {
    let state = {processInProgress: false}
    {
      process: processConfig => {
        // Check if already processing
        if state.processInProgress {
          Js.Exn.raiseError(
            "createTestIndexer process is already running. Only one process call is allowed at a time",
          )
        }

        // Validate chains
        let chains: Js.Dict.t<chainConfig> =
          (processConfig->Utils.magic)["chains"]->Utils.magic
        let chainKeys = chains->Js.Dict.keys

        switch chainKeys->Array.length {
        | 0 => Js.Exn.raiseError("createTestIndexer requires exactly one chain to be defined")
        | 1 => ()
        | n =>
          Js.Exn.raiseError(
            `createTestIndexer does not support processing multiple chains at once. Found ${n->Int.toString} chains defined`,
          )
        }

        // Create store for this run
        let store = makeStore(~allEntities)

        // Create initialState from processConfig chains
        let initialState = makeInitialState(~config, ~processConfigChains=chains)

        Promise.make((resolve, reject) => {
          // Include initialState in workerData
          let workerDataObj = {
            "processConfig": processConfig->Utils.magic->Js.Json.serializeExn->Js.Json.parseExn,
            "initialState": initialState->Utils.magic,
          }
          let workerData = workerDataObj->Js.Json.serializeExn->Js.Json.parseExn
          let worker = try {
            NodeJs.WorkerThreads.makeWorker(workerPath, {workerData: workerData})
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
            | LoadByIds({tableName, ids}) => store->handleLoadByIds(~tableName, ~ids)->respond

            | LoadByField({tableName, fieldName, fieldValue, operator}) =>
              store->handleLoadByField(~tableName, ~fieldName, ~fieldValue, ~operator)->respond

            | WriteBatch({updatedEntities}) =>
              store->handleWriteBatch(~updatedEntities)
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
              reject(Js.Exn.raiseError(`Worker exited with code ${code->Int.toString}`))
            } else {
              // Worker exited successfully (SuccessExit was dispatched in GlobalState)
              let changes = store->extractChanges
              resolve({
                checkpoints: [],
                changes,
              })
            }
          })
        })
      },
    }
  }
}

type workerData = {
  processConfig: Js.Json.t,
  initialState: Persistence.initialState,
}

let initTestWorker = (
  ~registerAllHandlers: unit => promise<EventRegister.registrations>,
  ~makeGeneratedConfig: unit => Config.t,
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

    Main.start(~registerAllHandlers, ~makeGeneratedConfig, ~persistence, ~isTest=true)->ignore
  | None =>
    Logging.error("TestIndexerWorker: No worker data provided")
    NodeJs.process->NodeJs.exitWithCode(Failure)
  }
}
