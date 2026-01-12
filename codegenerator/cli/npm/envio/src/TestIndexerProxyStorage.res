open Belt

// Message types for communication between worker and main thread
type requestId = int

// Serializable change with entity as JSON (for worker thread messaging)
@tag("type")
type serializableChange =
  | @as("SET") Set({entityId: string, entity: Js.Json.t, checkpointId: float})
  | @as("DELETE") Delete({entityId: string, checkpointId: float})

type serializableEntityUpdate = {
  latestChange: serializableChange,
  history: array<serializableChange>,
  containsRollbackDiffChange: bool,
}

type serializableUpdatedEntity = {
  entityName: string,
  updates: array<serializableEntityUpdate>,
}

// Worker -> Main thread payloads
@tag("type")
type workerPayload =
  | @as("loadByIds") LoadByIds({tableName: string, ids: array<string>})
  | @as("loadByField")
  LoadByField({
      tableName: string,
      fieldName: string,
      fieldValue: Js.Json.t,
      operator: Persistence.operator,
    })
  | @as("writeBatch")
  WriteBatch({
      updatedEntities: array<serializableUpdatedEntity>,
      checkpointIds: array<float>,
      checkpointChainIds: array<int>,
      checkpointBlockNumbers: array<int>,
      checkpointBlockHashes: array<Js.Null.t<string>>,
      checkpointEventsProcessed: array<int>,
    })

// Main thread -> Worker payloads
@tag("type")
type mainPayload =
  | @as("response") Response({data: Js.Json.t})
  | @as("error") Error({message: string})

// Message wrapper with id
type message<'payload> = {id: requestId, payload: 'payload}
type workerMessage = message<workerPayload>
type mainMessage = message<mainPayload>

// Pending request tracker
type pendingRequest = {
  resolve: Js.Json.t => unit,
  reject: exn => unit,
}

type t = {
  parentPort: NodeJs.WorkerThreads.messagePort,
  initialState: Persistence.initialState,
  pendingRequests: dict<pendingRequest>,
  mutable requestCounter: int,
}

let make = (~parentPort, ~initialState): t => {
  let proxy = {
    parentPort,
    initialState,
    pendingRequests: Js.Dict.empty(),
    requestCounter: 0,
  }

  // Set up message listener for responses from main thread
  parentPort->NodeJs.WorkerThreads.onPortMessage((msg: mainMessage) => {
    let idStr = msg.id->Int.toString
    let {resolve, reject} = switch proxy.pendingRequests->Utils.Dict.dangerouslyGetNonOption(
      idStr,
    ) {
    | Some(pending) => pending
    | None => Js.Exn.raiseError(`TestIndexer: No pending request found for id ${idStr}`)
    }
    Js.Dict.unsafeDeleteKey(proxy.pendingRequests->Obj.magic, idStr)

    switch msg.payload {
    | Response({data}) => resolve(data)
    | Error({message}) => reject(Js.Exn.raiseError(message))
    }
  })

  proxy
}

let nextRequestId = (proxy: t): requestId => {
  proxy.requestCounter = proxy.requestCounter + 1
  proxy.requestCounter
}

let sendRequest = (proxy: t, ~payload: workerPayload): promise<Js.Json.t> => {
  Promise.make((resolve, reject) => {
    let id = proxy->nextRequestId
    proxy.pendingRequests->Js.Dict.set(id->Int.toString, {resolve, reject})
    proxy.parentPort->NodeJs.WorkerThreads.postMessage({id, payload})
  })
}

let makeStorage = (proxy: t): Persistence.storage => {
  isInitialized: async () => true,
  initialize: async (~chainConfigs as _=?, ~entities as _=?, ~enums as _=?) => {
    Js.Exn.raiseError(
      "TestIndexer: initialize should not be called. Use resumeInitialState instead.",
    )
  },
  resumeInitialState: async () => proxy.initialState,
  loadByIdsOrThrow: async (~ids, ~table: Table.table, ~rowsSchema) => {
    let response = await proxy->sendRequest(~payload=LoadByIds({tableName: table.tableName, ids}))
    response->S.parseOrThrow(rowsSchema)
  },
  loadByFieldOrThrow: async (
    ~fieldName,
    ~fieldSchema,
    ~fieldValue,
    ~operator,
    ~table: Table.table,
    ~rowsSchema,
  ) => {
    let response = await proxy->sendRequest(
      ~payload=LoadByField({
        tableName: table.tableName,
        fieldName,
        fieldValue: fieldValue->S.reverseConvertToJsonOrThrow(fieldSchema),
        operator,
      }),
    )
    response->S.parseOrThrow(rowsSchema)
  },
  setOrThrow: async (~items as _, ~table as _, ~itemSchema as _) => {
    // Not used anywhere, no-op
    ()
  },
  writeBatch: async (
    ~batch,
    ~rawEvents as _,
    ~rollbackTargetCheckpointId as _,
    ~isInReorgThreshold as _,
    ~config as _,
    ~allEntities as _,
    ~updatedEffectsCache as _,
    ~updatedEntities,
  ) => {
    // Encode entities to JSON for serialization across worker boundary
    let serializableEntities = updatedEntities->Array.map(({
      entityConfig,
      updates,
    }: Persistence.updatedEntity) => {
      let encodeChange = (change: Change.t<Internal.entity>): serializableChange => {
        switch change {
        | Set({entityId, entity, checkpointId}) =>
          Set({
            entityId,
            entity: entity->S.reverseConvertToJsonOrThrow(entityConfig.schema),
            checkpointId,
          })
        | Delete({entityId, checkpointId}) => Delete({entityId, checkpointId})
        }
      }
      {
        entityName: entityConfig.name,
        updates: updates->Array.map(update => {
          latestChange: encodeChange(update.latestChange),
          history: update.history->Array.map(encodeChange),
          containsRollbackDiffChange: update.containsRollbackDiffChange,
        }),
      }
    })
    let _ = await proxy->sendRequest(
      ~payload=WriteBatch({
        updatedEntities: serializableEntities,
        checkpointIds: batch.checkpointIds,
        checkpointChainIds: batch.checkpointChainIds,
        checkpointBlockNumbers: batch.checkpointBlockNumbers,
        checkpointBlockHashes: batch.checkpointBlockHashes,
        checkpointEventsProcessed: batch.checkpointEventsProcessed,
      }),
    )
  },
  setEffectCacheOrThrow: async (~effect as _, ~items as _, ~initialize as _) => (),
  dumpEffectCache: async () => (),
  executeUnsafe: async _ => Obj.magic(),
  hasEntityHistoryRows: async () => false,
  setChainMeta: async _ => Obj.magic(),
  pruneStaleCheckpoints: async (~safeCheckpointId as _) => (),
  pruneStaleEntityHistory: async (~entityName as _, ~entityIndex as _, ~safeCheckpointId as _) =>
    (),
  getRollbackTargetCheckpoint: async (~reorgChainId as _, ~lastKnownValidBlockNumber as _) => {
    Js.Exn.raiseError(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
    )
  },
  getRollbackProgressDiff: async (~rollbackTargetCheckpointId as _) => {
    Js.Exn.raiseError(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
    )
  },
  getRollbackData: async (~entityConfig as _, ~rollbackTargetCheckpointId as _) => {
    Js.Exn.raiseError(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
    )
  },
}
