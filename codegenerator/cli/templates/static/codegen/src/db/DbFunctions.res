type chainId = int
type eventId = string
type blockNumberRow = {@as("block_number") blockNumber: int}

// Copied from ReScript Schema to quote and escape "
let quote = (string: string): string => {
  let rec loop = idx => {
    switch string->Js.String2.get(idx)->(Utils.magic: string => option<string>) {
    | None => `"${string}"`
    | Some("\"") => string->Js.Json.stringifyAny->Obj.magic
    | Some(_) => loop(idx + 1)
    }
  }
  loop(0)
}

@module("./DbFunctionsImplementation.js")
external makeBatchSetEntityValues: Table.table => (Postgres.sql, unknown) => promise<unit> =
  "makeBatchSetEntityValues"

let makeTableBatchSet = (table, schema: S.t<'entity>) => {
  let {dbSchema, quotedFieldNames, quotedNonPrimaryFieldNames, arrayFieldTypes, hasArrayField} =
    table->Table.toSqlParams(~schema)
  let isRawEvents = table.tableName === TablesStatic.RawEvents.table.tableName

  let typeValidation = false

  if isRawEvents || !hasArrayField {
    let convertOrThrow = S.compile(
      S.unnest(dbSchema),
      ~input=Value,
      ~output=Unknown,
      ~mode=Sync,
      ~typeValidation,
    )

    let primaryKeyFieldNames = Table.getPrimaryKeyFieldNames(table)

    let unsafeSql =
      `
INSERT INTO "public".${table.tableName->quote} (${quotedFieldNames->Js.Array2.joinWith(", ")})
SELECT * FROM unnest(${arrayFieldTypes
        ->Js.Array2.mapi((arrayFieldType, idx) => {
          `$${(idx + 1)->Js.Int.toString}::${arrayFieldType}`
        })
        ->Js.Array2.joinWith(",")})` ++
      switch (isRawEvents, primaryKeyFieldNames) {
      | (true, _)
      | (_, []) => ``
      | (false, primaryKeyFieldNames) =>
        `ON CONFLICT(${primaryKeyFieldNames
          ->Js.Array2.map(quote)
          ->Js.Array2.joinWith(",")}) DO ` ++ (
          quotedNonPrimaryFieldNames->Utils.Array.isEmpty
            ? `NOTHING`
            : `UPDATE SET ${quotedNonPrimaryFieldNames
                ->Js.Array2.map(fieldName => {
                  `${fieldName} = EXCLUDED.${fieldName}`
                })
                ->Js.Array2.joinWith(",")}`
        )
      } ++ ";"

    (sql, entityDataArray: array<'entity>): promise<unit> => {
      sql->Postgres.preparedUnsafe(unsafeSql, convertOrThrow(entityDataArray))
    }
  } else {
    let convertOrThrow = S.compile(
      S.array(schema),
      ~input=Value,
      ~output=Unknown,
      ~mode=Sync,
      ~typeValidation,
    )

    let query = makeBatchSetEntityValues(table)

    (sql, entityDataArray: array<'entity>): promise<unit> => {
      query(sql, convertOrThrow(entityDataArray))
    }
  }
}

module General = {
  type existsRes = {exists: bool}

  let hasRows = async (sql, ~table: Table.table) => {
    let query = `SELECT EXISTS(SELECT 1 FROM public."${table.tableName}");`
    switch await sql->Postgres.unsafe(query) {
    | [{exists}] => exists
    | _ => Js.Exn.raiseError("Unexpected result from hasRows query: " ++ query)
    }
  }
}

module ChainMetadata = {
  type chainMetadata = {
    @as("chain_id") chainId: int,
    @as("block_height") blockHeight: int,
    @as("start_block") startBlock: int,
    @as("end_block") endBlock: option<int>,
    @as("first_event_block_number") firstEventBlockNumber: option<int>,
    @as("latest_processed_block") latestProcessedBlock: option<int>,
    @as("num_events_processed") numEventsProcessed: option<int>,
    @as("is_hyper_sync") poweredByHyperSync: bool,
    @as("num_batches_fetched") numBatchesFetched: int,
    @as("latest_fetched_block_number") latestFetchedBlockNumber: int,
    @as("timestamp_caught_up_to_head_or_endblock")
    timestampCaughtUpToHeadOrEndblock: Js.Nullable.t<Js.Date.t>,
  }

  @module("./DbFunctionsImplementation.js")
  external batchSetChainMetadata: (Postgres.sql, array<chainMetadata>) => promise<unit> =
    "batchSetChainMetadata"

  @module("./DbFunctionsImplementation.js")
  external readLatestChainMetadataState: (
    Postgres.sql,
    ~chainId: int,
  ) => promise<array<chainMetadata>> = "readLatestChainMetadataState"

  let batchSetChainMetadataRow = (sql, ~chainMetadataArray: array<chainMetadata>) => {
    sql->batchSetChainMetadata(chainMetadataArray)
  }

  let getLatestChainMetadataState = async (sql, ~chainId) => {
    let arr = await sql->readLatestChainMetadataState(~chainId)
    arr->Belt.Array.get(0)
  }
}

module EndOfBlockRangeScannedData = {
  type endOfBlockRangeScannedData = {
    @as("chain_id") chainId: int,
    @as("block_number") blockNumber: int,
    @as("block_hash") blockHash: string,
  }

  @module("./DbFunctionsImplementation.js")
  external batchSet: (Postgres.sql, array<endOfBlockRangeScannedData>) => promise<unit> =
    "batchSetEndOfBlockRangeScannedData"

  let setEndOfBlockRangeScannedData = (sql, endOfBlockRangeScannedData) =>
    batchSet(sql, [endOfBlockRangeScannedData])

  @module("./DbFunctionsImplementation.js")
  external readEndOfBlockRangeScannedDataForChain: (
    Postgres.sql,
    ~chainId: int,
  ) => promise<array<endOfBlockRangeScannedData>> = "readEndOfBlockRangeScannedDataForChain"

  @module("./DbFunctionsImplementation.js")
  external deleteStaleEndOfBlockRangeScannedDataForChain: (
    Postgres.sql,
    ~chainId: int,
    //minimum blockNumber that should be kept in db
    ~blockNumberThreshold: int,
  ) => promise<unit> = "deleteStaleEndOfBlockRangeScannedDataForChain"
}

module EventSyncState = {
  @genType
  type eventSyncState = TablesStatic.EventSyncState.t

  @module("./DbFunctionsImplementation.js")
  external readLatestSyncedEventOnChainIdArr: (
    Postgres.sql,
    ~chainId: int,
  ) => promise<array<eventSyncState>> = "readLatestSyncedEventOnChainId"

  let readLatestSyncedEventOnChainId = async (sql, ~chainId) => {
    let arr = await sql->readLatestSyncedEventOnChainIdArr(~chainId)
    arr->Belt.Array.get(0)
  }

  let getLatestProcessedEvent = (sql, ~chainId) => {
    sql->readLatestSyncedEventOnChainId(~chainId)
  }

  @module("./DbFunctionsImplementation.js")
  external batchSet: (Postgres.sql, array<TablesStatic.EventSyncState.t>) => promise<unit> =
    "batchSetEventSyncState"
}

module RawEvents = {
  let batchSet = makeTableBatchSet(TablesStatic.RawEvents.table, TablesStatic.RawEvents.schema)
}

module DynamicContractRegistry = {
  @module("./DbFunctionsImplementation.js")
  external deleteInvalidDynamicContractsOnRestart: (
    Postgres.sql,
    ~chainId: chainId,
    ~restartBlockNumber: int,
    ~restartLogIndex: int,
  ) => promise<unit> = "deleteInvalidDynamicContractsOnRestart"

  @module("./DbFunctionsImplementation.js")
  external deleteInvalidDynamicContractsHistoryOnRestart: (
    Postgres.sql,
    ~chainId: chainId,
    ~restartBlockNumber: int,
    ~restartLogIndex: int,
  ) => promise<unit> = "deleteInvalidDynamicContractsHistoryOnRestart"

  @module("./DbFunctionsImplementation.js")
  external readAllDynamicContractsRaw: (Postgres.sql, ~chainId: chainId) => promise<Js.Json.t> =
    "readAllDynamicContracts"

  let readAllDynamicContracts = async (sql: Postgres.sql, ~chainId: chainId) => {
    let json = await sql->readAllDynamicContractsRaw(~chainId)
    json->S.parseJsonOrThrow(TablesStatic.DynamicContractRegistry.rowsSchema)
  }
}

module EntityHistory = {
  type dynamicSqlQuery
  module UnorderedMultichain = {
    @module("./DbFunctionsImplementation.js")
    external getFirstChangeSerial: (
      Postgres.sql,
      ~reorgChainId: int,
      ~safeBlockNumber: int,
      ~entityName: Enums.EntityType.t,
    ) => dynamicSqlQuery = "getFirstChangeSerial_UnorderedMultichain"
  }

  module OrderedMultichain = {
    @module("./DbFunctionsImplementation.js")
    external getFirstChangeSerial: (
      Postgres.sql,
      ~safeBlockTimestamp: int,
      ~reorgChainId: int,
      ~safeBlockNumber: int,
      ~entityName: Enums.EntityType.t,
    ) => dynamicSqlQuery = "getFirstChangeSerial_OrderedMultichain"
  }

  @module("./DbFunctionsImplementation.js")
  external getFirstChangeEntityHistoryPerChain: (
    Postgres.sql,
    ~entityName: Enums.EntityType.t,
    ~getFirstChangeSerial: Postgres.sql => dynamicSqlQuery,
  ) => promise<Js.Json.t> = "getFirstChangeEntityHistoryPerChain"

  @module("./DbFunctionsImplementation.js")
  external getRollbackDiffInternal: (
    Postgres.sql,
    ~entityName: Enums.EntityType.t,
    ~getFirstChangeSerial: Postgres.sql => dynamicSqlQuery,
  ) => //Returns an array of entity history rows
  promise<Js.Json.t> = "getRollbackDiff"

  @module("./DbFunctionsImplementation.js")
  external deleteRolledBackEntityHistory: (
    Postgres.sql,
    ~entityName: Enums.EntityType.t,
    ~getFirstChangeSerial: Postgres.sql => dynamicSqlQuery,
  ) => promise<unit> = "deleteRolledBackEntityHistory"

  type chainIdAndBlockNumber = {
    chainId: int,
    blockNumber: int,
  }

  @module("./DbFunctionsImplementation.js")
  external pruneStaleEntityHistoryInternal: (
    Postgres.sql,
    ~entityName: Enums.EntityType.t,
    ~safeChainIdAndBlockNumberArray: array<chainIdAndBlockNumber>,
    // shouldDeepClean is a boolean that determines whether to delete stale history
    // items of entities that are in the reorg threshold (expensive to calculate)
    // or to do a shallow clean (only deletes history items of entities that are not in the reorg threshold)
    ~shouldDeepClean: bool,
  ) => promise<unit> = "pruneStaleEntityHistory"

  let rollbacksGroup = "Rollbacks"

  let pruneStaleEntityHistory = async (
    sql,
    ~entityName,
    ~safeChainIdAndBlockNumberArray,
    ~shouldDeepClean,
  ) => {
    try await sql->pruneStaleEntityHistoryInternal(
      ~entityName,
      ~safeChainIdAndBlockNumberArray,
      ~shouldDeepClean,
    ) catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~msg=`Failed to prune stale entity history`,
        ~logger=Logging.createChild(
          ~params={
            "entityName": entityName,
            "safeChainIdAndBlockNumberArray": safeChainIdAndBlockNumberArray,
          },
        ),
      )
    }
  }

  module Args = {
    type t =
      | OrderedMultichain({safeBlockTimestamp: int, reorgChainId: int, safeBlockNumber: int})
      | UnorderedMultichain({reorgChainId: int, safeBlockNumber: int})

    /**
    Uses two different methods for determining the first change event after rollback block

    This is needed since unordered multichain mode only cares about any changes that 
    occurred after the first change on the reorg chain. To prevent skipping or double processing events
    on the other chains. If for instance there are no entity changes based on the reorg chain, the other
    chains do not need to be rolled back, and if the reorg chain has new included events, it does not matter
    that if those events are processed out of order from other chains since this is "unordered_multichain_mode"

    Ordered multichain mode needs to ensure that all chains rollback to any event that occurred after the reorg chain
    block number. Regardless of whether the reorg chain incurred any changes or not to entities.
    */
    let makeGetFirstChangeSerial = (self: t, ~entityName) =>
      switch self {
      | OrderedMultichain({safeBlockTimestamp, reorgChainId, safeBlockNumber}) =>
        sql =>
          OrderedMultichain.getFirstChangeSerial(
            sql,
            ~safeBlockTimestamp,
            ~reorgChainId,
            ~safeBlockNumber,
            ~entityName,
          )
      | UnorderedMultichain({reorgChainId, safeBlockNumber}) =>
        sql =>
          UnorderedMultichain.getFirstChangeSerial(
            sql,
            ~reorgChainId,
            ~safeBlockNumber,
            ~entityName,
          )
      }

    let getLogger = (self: t, ~entityName) => {
      switch self {
      | OrderedMultichain({safeBlockTimestamp, reorgChainId, safeBlockNumber}) =>
        Logging.createChild(
          ~params={
            "type": "OrderedMultichain",
            "safeBlockTimestamp": safeBlockTimestamp,
            "reorgChainId": reorgChainId,
            "safeBlockNumber": safeBlockNumber,
            "entityName": entityName,
          },
        )
      | UnorderedMultichain({reorgChainId, safeBlockNumber}) =>
        Logging.createChild(
          ~params={
            "type": "UnorderedMultichain",
            "reorgChainId": reorgChainId,
            "safeBlockNumber": safeBlockNumber,
            "entityName": entityName,
          },
        )
      }
    }
  }

  let deleteAllEntityHistoryAfterEventIdentifier = async (
    sql,
    ~isUnorderedMultichainMode,
    ~eventIdentifier: Types.eventIdentifier,
    ~allEntities=Entities.allEntities,
  ): unit => {
    let startTime = Hrtime.makeTimer()

    let {chainId, blockNumber, blockTimestamp} = eventIdentifier
    let args: Args.t = isUnorderedMultichainMode
      ? UnorderedMultichain({reorgChainId: chainId, safeBlockNumber: blockNumber})
      : OrderedMultichain({
          reorgChainId: chainId,
          safeBlockNumber: blockNumber,
          safeBlockTimestamp: blockTimestamp,
        })

    let _ =
      await allEntities
      ->Belt.Array.map(async entityMod => {
        let module(Entity) = entityMod
        try await deleteRolledBackEntityHistory(
          sql,
          ~entityName=Entity.name,
          ~getFirstChangeSerial=args->Args.makeGetFirstChangeSerial(~entityName=Entity.name),
        ) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to delete rolled back entity history`,
            ~logger=args->Args.getLogger(~entityName=Entity.name),
          )
        }
      })
      ->Promise.all

    if Env.Benchmark.shouldSaveData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Delete Rolled Back History Time (ms)`,
        ~value=elapsedTimeMillis,
      )
    }
  }

  let getRollbackDiff = async (
    type entity,
    sql,
    args: Args.t,
    ~entityMod: module(Entities.Entity with type t = entity),
  ) => {
    let module(Entity) = entityMod
    let startTime = Hrtime.makeTimer()

    let diffRes = switch await getRollbackDiffInternal(
      sql,
      ~getFirstChangeSerial=args->Args.makeGetFirstChangeSerial(~entityName=Entity.name),
      ~entityName=Entity.name,
    ) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~msg="Failed to get rollback diff from entity history",
        ~logger=args->Args.getLogger(~entityName=Entity.name),
      )
    | res => res
    }

    if Env.Benchmark.shouldSaveData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Diff Creation Time (ms)`,
        ~value=elapsedTimeMillis,
      )
    }

    switch diffRes->S.parseOrThrow(Entity.entityHistory.schemaRows) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~msg="Failed to parse rollback diff from entity history",
        ~logger=args->Args.getLogger(~entityName=Entity.name),
      )
    | diffRows => diffRows
    }
  }

  module FirstChangeEventPerChain = {
    type t = Js.Dict.t<FetchState.blockNumberAndLogIndex>
    let getKey = chainId => chainId->Belt.Int.toString
    let make = () => Js.Dict.empty()
    let get = (self: t, ~chainId) => self->Utils.Dict.dangerouslyGetNonOption(getKey(chainId))

    let setIfEarlier = (self: t, ~chainId, ~event: FetchState.blockNumberAndLogIndex) => {
      let chainKey = chainId->Belt.Int.toString
      switch self->Utils.Dict.dangerouslyGetNonOption(chainKey) {
      | Some(existingEvent) =>
        if (
          (event.blockNumber, event.logIndex) < (existingEvent.blockNumber, existingEvent.logIndex)
        ) {
          self->Js.Dict.set(chainKey, event)
        }
      | None => self->Js.Dict.set(chainKey, event)
      }
    }
  }

  let getFirstChangeEventPerChain = async (
    sql,
    args: Args.t,
    ~allEntities=Entities.allEntities,
  ) => {
    let startTime = Hrtime.makeTimer()
    let firstChangeEventPerChain = FirstChangeEventPerChain.make()

    let _ =
      await allEntities
      ->Belt.Array.map(async entityMod => {
        let module(Entity) = entityMod
        let res = try await getFirstChangeEntityHistoryPerChain(
          sql,
          ~entityName=Entity.name,
          ~getFirstChangeSerial=args->Args.makeGetFirstChangeSerial(~entityName=Entity.name),
        ) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to get first change entity history per chain for entity`,
            ~logger=args->Args.getLogger(~entityName=Entity.name),
          )
        }

        let chainHistoryRows = try res->S.parseOrThrow(Entity.entityHistory.schemaRows) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to parse entity history rows from db on getFirstChangeEntityHistoryPerChain`,
            ~logger=args->Args.getLogger(~entityName=Entity.name),
          )
        }

        chainHistoryRows->Belt.Array.forEach(chainHistoryRow => {
          firstChangeEventPerChain->FirstChangeEventPerChain.setIfEarlier(
            ~chainId=chainHistoryRow.current.chain_id,
            ~event={
              blockNumber: chainHistoryRow.current.block_number,
              logIndex: chainHistoryRow.current.log_index,
            },
          )
        })
      })
      ->Promise.all

    if Env.Benchmark.shouldSaveData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Get First Change Event Per Chain Time (ms)`,
        ~value=elapsedTimeMillis,
      )
    }

    firstChangeEventPerChain
  }

  let hasRows = async sql => {
    let all =
      await Entities.allEntities
      ->Belt.Array.map(async entityMod => {
        let module(Entity) = entityMod
        try await General.hasRows(sql, ~table=Entity.entityHistory.table) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to check if entity history table has rows`,
            ~logger=Logging.createChild(
              ~params={
                "entityName": Entity.name,
              },
            ),
          )
        }
      })
      ->Promise.all
    all->Belt.Array.some(v => v)
  }
}
