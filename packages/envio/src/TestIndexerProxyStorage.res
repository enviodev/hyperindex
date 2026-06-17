// Message types for communication between worker and main thread
type requestId = int

// Serializable change with entity as JSON (for worker thread messaging)
@tag("type")
type serializableChange =
  | @as("SET") Set({entityId: string, entity: JSON.t, checkpointId: bigint})
  | @as("DELETE") Delete({entityId: string, checkpointId: bigint})

type serializableUpdatedEntity = {
  entityName: string,
  changes: array<serializableChange>,
}

// Worker -> Main thread payloads
@tag("type")
type workerPayload =
  | @as("load")
  Load({
      tableName: string,
      // Leaf field values are JSON-serialized with the table's field schemas
      filter: EntityFilter.t,
    })
  | @as("writeBatch")
  WriteBatch({
      updatedEntities: array<serializableUpdatedEntity>,
      checkpointIds: array<bigint>,
      checkpointChainIds: array<int>,
      checkpointBlockNumbers: array<int>,
      checkpointBlockHashes: array<Null.t<string>>,
      checkpointEventsProcessed: array<int>,
    })

// Main thread -> Worker payloads
@tag("type")
type mainPayload =
  | @as("response") Response({data: JSON.t})
  | @as("error") Error({message: string})

// Message wrapper with id
type message<'payload> = {id: requestId, payload: 'payload}
type workerMessage = message<workerPayload>
type mainMessage = message<mainPayload>

// Pending request tracker
type pendingRequest = {
  resolve: JSON.t => unit,
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
    pendingRequests: Dict.make(),
    requestCounter: 0,
  }

  // Set up message listener for responses from main thread
  parentPort->NodeJs.WorkerThreads.onPortMessage((msg: mainMessage) => {
    let idStr = msg.id->Int.toString
    let {resolve, reject} = switch proxy.pendingRequests->Utils.Dict.dangerouslyGetNonOption(
      idStr,
    ) {
    | Some(pending) => pending
    | None => JsError.throwWithMessage(`TestIndexer: No pending request found for id ${idStr}`)
    }
    Dict.delete(proxy.pendingRequests->Obj.magic, idStr)

    switch msg.payload {
    | Response({data}) => resolve(data)
    | Error({message}) => reject(Utils.Error.make(message))
    }
  })

  proxy
}

let nextRequestId = (proxy: t): requestId => {
  proxy.requestCounter = proxy.requestCounter + 1
  proxy.requestCounter
}

let sendRequest = (proxy: t, ~payload: workerPayload): promise<JSON.t> => {
  Promise.make((resolve, reject) => {
    let id = proxy->nextRequestId
    proxy.pendingRequests->Dict.set(id->Int.toString, {resolve, reject})
    proxy.parentPort->NodeJs.WorkerThreads.postMessage({id, payload})
  })
}

let makeStorage = (proxy: t): Persistence.storage => {
  name: "test-proxy",
  isInitialized: async () => true,
  initialize: async (~chainConfigs as _=?, ~entities as _=?, ~enums as _=?, ~envioInfo as _) => {
    JsError.throwWithMessage(
      "TestIndexer: initialize should not be called. Use resumeInitialState instead.",
    )
  },
  resumeInitialState: async () => proxy.initialState,
  loadOrThrow: async (~filter, ~table: Table.table) => {
    let serializeLeafOrThrow = (~fieldName, ~fieldValue: unknown, ~isArray) => {
      let queryField = switch table->Table.queryFields->Dict.get(fieldName) {
      | Some(queryField) => queryField
      | None =>
        JsError.throwWithMessage(
          `TestIndexer: The table "${table.tableName}" doesn't have the field "${fieldName}"`,
        )
      }
      fieldValue
      ->S.reverseConvertToJsonOrThrow(
        isArray ? queryField.arrayFieldSchema : queryField.fieldSchema,
      )
      ->(Utils.magic: JSON.t => unknown)
    }
    let response = await proxy->sendRequest(
      ~payload=Load({
        tableName: table.tableName,
        // Field values must be JSON-safe to survive the worker thread boundary
        filter: filter->EntityFilter.mapValues(~mapValue=serializeLeafOrThrow),
      }),
    )
    response->S.parseOrThrow(table->Table.rowsSchema)
  },
  writeBatch: async (
    ~batch,
    ~rollback as _,
    ~isInReorgThreshold as _,
    ~config as _,
    ~allEntities as _,
    ~updatedEffectsCache as _,
    ~updatedEntities,
    ~chainMetaData as _,
  ) => {
    // Encode entities to JSON for serialization across worker boundary
    let serializableEntities = updatedEntities->Array.map((
      {entityConfig, changes}: Persistence.updatedEntity,
    ) => {
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
        changes: changes->Array.map(encodeChange),
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
  dumpEffectCache: async () => (),
  reset: async () => (),
  setChainMeta: async _ => Obj.magic(),
  pruneStaleCheckpoints: async (~safeCheckpointId as _) => (),
  pruneStaleEntityHistory: async (~entityConfig as _, ~safeCheckpointId as _) => (),
  getRollbackTargetCheckpoint: async (~reorgChainId as _, ~lastKnownValidBlockNumber as _) => {
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
    )
  },
  getRollbackProgressDiff: async (~rollbackTargetCheckpointId as _) => {
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
    )
  },
  getRollbackData: async (~entityConfig as _, ~rollbackTargetCheckpointId as _) => {
    JsError.throwWithMessage(
      "TestIndexer: Rollback is not supported. Set rollbackOnReorg to false in config.",
    )
  },
  close: async () => (),
}
