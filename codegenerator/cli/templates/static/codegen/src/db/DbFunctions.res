let config: Postgres.poolConfig = {
  host: Env.Db.host,
  port: Env.Db.port,
  username: Env.Db.user,
  password: Env.Db.password,
  database: Env.Db.database,
  ssl: Env.Db.ssl,
  // TODO: think how we want to pipe these logs to pino.
  onnotice: ?(Env.userLogLevel == #warn || Env.userLogLevel == #error ? None : Some(_str => ())),
  transform: {undefined: Null},
  max: 2,
}
let sql = Postgres.makeSql(~config)

type chainId = int
type eventId = string
type blockNumberRow = {@as("block_number") blockNumber: int}

module General = {
  type existsRes = {exists: bool}

  let hasRows = async (sql, ~table: Table.table) => {
    let query = `SELECT EXISTS(SELECT 1 FROM public.${table.tableName});`
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
  external setChainMetadataBlockHeight: (Postgres.sql, chainMetadata) => promise<unit> =
    "setChainMetadataBlockHeight"
  @module("./DbFunctionsImplementation.js")
  external batchSetChainMetadata: (Postgres.sql, array<chainMetadata>) => promise<unit> =
    "batchSetChainMetadata"

  @module("./DbFunctionsImplementation.js")
  external readLatestChainMetadataState: (
    Postgres.sql,
    ~chainId: int,
  ) => promise<array<chainMetadata>> = "readLatestChainMetadataState"

  let setChainMetadataBlockHeightRow = (~chainMetadata: chainMetadata) => {
    sql->setChainMetadataBlockHeight(chainMetadata)
  }

  let batchSetChainMetadataRow = (~chainMetadataArray: array<chainMetadata>) => {
    sql->batchSetChainMetadata(chainMetadataArray)
  }

  let getLatestChainMetadataState = async (~chainId) => {
    let arr = await sql->readLatestChainMetadataState(~chainId)
    arr->Belt.Array.get(0)
  }
}

module EndOfBlockRangeScannedData = {
  type endOfBlockRangeScannedData = {
    @as("chain_id") chainId: int,
    @as("block_timestamp") blockTimestamp: int,
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
    //minimum blockTimestamp that should be kept in db
    //(timestamp could be lower/higher than blockTimestampThreshold depending on multichain configuration)
    ~blockTimestampThreshold: int,
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

  let getLatestProcessedEvent = (~chainId) => {
    sql->readLatestSyncedEventOnChainId(~chainId)
  }

  @module("./DbFunctionsImplementation.js")
  external batchSet: (Postgres.sql, array<TablesStatic.EventSyncState.t>) => promise<unit> =
    "batchSetEventSyncState"
}

module RawEvents = {
  type rawEventRowId = (chainId, eventId)
  @module("./DbFunctionsImplementation.js")
  external batchSet: (Postgres.sql, array<TablesStatic.RawEvents.t>) => promise<unit> =
    "batchSetRawEvents"

  @module("./DbFunctionsImplementation.js")
  external batchDelete: (Postgres.sql, array<rawEventRowId>) => promise<unit> =
    "batchDeleteRawEvents"

  @module("./DbFunctionsImplementation.js")
  external readEntities: (
    Postgres.sql,
    array<rawEventRowId>,
  ) => promise<array<TablesStatic.RawEvents.t>> = "readRawEventsEntities"

  @module("./DbFunctionsImplementation.js")
  external getRawEventsPageGtOrEqEventId: (
    Postgres.sql,
    ~chainId: chainId,
    ~eventId: bigint,
    ~limit: int,
    ~contractAddresses: array<Address.t>,
  ) => promise<array<TablesStatic.RawEvents.t>> = "getRawEventsPageGtOrEqEventId"

  @module("./DbFunctionsImplementation.js")
  external getRawEventsPageWithinEventIdRangeInclusive: (
    Postgres.sql,
    ~chainId: chainId,
    ~fromEventIdInclusive: bigint,
    ~toEventIdInclusive: bigint,
    ~limit: int,
    ~contractAddresses: array<Address.t>,
  ) => promise<array<TablesStatic.RawEvents.t>> = "getRawEventsPageWithinEventIdRangeInclusive"

  ///Returns an array with 1 block number (the highest processed on the given chainId)
  @module("./DbFunctionsImplementation.js")
  external readLatestRawEventsBlockNumberProcessedOnChainId: (
    Postgres.sql,
    chainId,
  ) => promise<array<blockNumberRow>> = "readLatestRawEventsBlockNumberProcessedOnChainId"

  let getLatestProcessedBlockNumber = async (~chainId) => {
    let row = await sql->readLatestRawEventsBlockNumberProcessedOnChainId(chainId)

    row->Belt.Array.get(0)->Belt.Option.map(row => row.blockNumber)
  }

  @module("./DbFunctionsImplementation.js")
  external deleteAllRawEventsAfterEventIdentifier: (
    Postgres.sql,
    ~eventIdentifier: Types.eventIdentifier,
  ) => promise<unit> = "deleteAllRawEventsAfterEventIdentifier"
}

module DynamicContractRegistry = {
  @module("./DbFunctionsImplementation.js")
  external readDynamicContractsOnChainIdAtOrBeforeBlockNumberRaw: (
    Postgres.sql,
    ~chainId: chainId,
    ~blockNumber: int,
  ) => promise<Js.Json.t> = "readDynamicContractsOnChainIdAtOrBeforeBlockNumber"

  let readDynamicContractsOnChainIdAtOrBeforeBlock = async (sql, ~chainId, ~startBlock) => {
    let json = await readDynamicContractsOnChainIdAtOrBeforeBlockNumberRaw(
      sql,
      ~chainId,
      ~blockNumber=startBlock,
    )
    json->S.parseOrRaiseWith(TablesStatic.DynamicContractRegistry.rowsSchema)
  }

  type preRegisteringEvent = {
    @as("registering_event_contract_name") registeringEventContractName: string,
    @as("registering_event_name") registeringEventName: string,
    @as("registering_event_src_address") registeringEventSrcAddress: Address.t,
  }

  @module("./DbFunctionsImplementation.js")
  external readDynamicContractsOnChainIdMatchingEventsRaw: (
    Postgres.sql,
    ~chainId: int,
    ~preRegisteringEvents: array<preRegisteringEvent>,
  ) => promise<Js.Json.t> = "readDynamicContractsOnChainIdMatchingEvents"

  let readDynamicContractsOnChainIdMatchingEvents = async (
    sql,
    ~chainId,
    ~preRegisteringEvents,
  ) => {
    switch await readDynamicContractsOnChainIdMatchingEventsRaw(
      sql,
      ~chainId,
      ~preRegisteringEvents,
    ) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~logger=Logging.createChild(~params={"chainId": chainId}),
        ~msg="Failed to read dynamic contracts on chain id matching events",
      )
    | json => json->S.parseOrRaiseWith(TablesStatic.DynamicContractRegistry.rowsSchema)
    }
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
  ) => promise<unit> = "pruneStaleEntityHistory"

  let rollbacksGroup = "Rollbacks"

  let pruneStaleEntityHistory = async (sql, ~entityName, ~safeChainIdAndBlockNumberArray) => {
    let startTime = Hrtime.makeTimer()
    try await sql->pruneStaleEntityHistoryInternal(
      ~entityName,
      ~safeChainIdAndBlockNumberArray,
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

    if Env.saveBenchmarkData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Prune Stale History Time (ms)`,
        ~value=elapsedTimeMillis,
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

    if Env.saveBenchmarkData {
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

    if Env.saveBenchmarkData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Diff Creation Time (ms)`,
        ~value=elapsedTimeMillis,
      )
    }

    switch diffRes->S.parseAnyOrRaiseWith(Entity.entityHistory.schemaRows) {
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

        let chainHistoryRows = try res->S.parseAnyOrRaiseWith(
          Entity.entityHistory.schemaRows,
        ) catch {
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

    if Env.saveBenchmarkData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Get First Change Event Per Chain Time (ms)`,
        ~value=elapsedTimeMillis,
      )
    }

    firstChangeEventPerChain
  }

  let hasRows = async () => {
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
