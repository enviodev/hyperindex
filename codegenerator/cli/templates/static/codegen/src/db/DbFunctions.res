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
  let batchSet = TablesStatic.DynamicContractRegistry.batchSet

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

  @module("./DbFunctionsImplementation.js")
  external deleteAllDynamicContractRegistrationsAfterEventIdentifier: (
    Postgres.sql,
    ~eventIdentifier: Types.eventIdentifier,
  ) => promise<unit> = "deleteAllDynamicContractRegistrationsAfterEventIdentifier"

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
  //Given chainId, blockTimestamp, blockNumber
  //Delete all rows where chain_id = chainId and block_timestamp < blockTimestamp and block_number < blockNumber
  //But keep 1 row that is satisfies this condition and has the most recent block_number
  @module("./DbFunctionsImplementation.js")
  external deleteAllEntityHistoryOnChainBeforeThreshold: (
    Postgres.sql,
    ~chainId: int,
    ~blockNumberThreshold: int,
    ~blockTimestampThreshold: int,
  ) => promise<unit> = "deleteAllEntityHistoryOnChainBeforeThreshold"

  @module("./DbFunctionsImplementation.js")
  external batchSetInternal: (
    Postgres.sql,
    ~entityHistoriesToSet: array<Js.Json.t>,
  ) => promise<unit> = "batchInsertEntityHistory"

  @module("./DbFunctionsImplementation.js")
  external deleteRolledBackEntityHistory: (
    Postgres.sql,
    ~reorgChainId: int,
    ~safeBlockNumber: int,
    ~entityName: Enums.EntityType.t,
  ) => promise<unit> = "deleteRolledBackEntityHistory"

  let deleteAllEntityHistoryAfterEventIdentifier = (
    sql,
    ~eventIdentifier: Types.eventIdentifier,
  ): promise<unit> => {
    let {chainId, blockNumber} = eventIdentifier

    Utils.Array.awaitEach(Entities.allEntities, async entityMod => {
      let module(Entity) = entityMod
      try await deleteRolledBackEntityHistory(
        sql,
        ~reorgChainId=chainId,
        ~safeBlockNumber=blockNumber,
        ~entityName=Entity.name,
      ) catch {
      | exn =>
        exn->ErrorHandling.mkLogAndRaise(
          ~msg=`Failed to delete rolled back entity history`,
          ~logger=Logging.createChild(
            ~params={
              "reorgChainId": chainId,
              "safeBlockNumber": blockNumber,
              "entityName": Entity.name,
            },
          ),
        )
      }
    })
  }

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

  module Args = {
    type t =
      | OrderedMultichain({safeBlockTimestamp: int, reorgChainId: int, safeBlockNumber: int})
      | UnorderedMultichain({reorgChainId: int, safeBlockNumber: int})

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

  let getRollbackDiff = async (
    type entity,
    sql,
    args: Args.t,
    ~entityMod: module(Entities.Entity with type t = entity),
  ) => {
    let module(Entity) = entityMod

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
    switch diffRes->S.parseAnyOrRaiseWith(Entity.entityHistory.schemaRows) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~msg="Failed to parse rollback diff from entity history",
        ~logger=args->Args.getLogger(~entityName=Entity.name),
      )
    | diffRows => diffRows
    }
  }

  module FirstChangeEventIdentifierPerChain = {
    type t = Js.Dict.t<Types.eventIdentifier>
    let getKey = chainId => chainId->Belt.Int.toString
    let make = () => Js.Dict.empty()
    let get = (self: t, ~chainId) => self->Utils.Dict.dangerouslyGetNonOption(getKey(chainId))

    let set = (self: t, ~eventIdentifier: Types.eventIdentifier) => {
      let chainKey = eventIdentifier.chainId->Belt.Int.toString
      switch self->Utils.Dict.dangerouslyGetNonOption(chainKey) {
      | Some(existingEventIdentifier) =>
        if (
          (existingEventIdentifier.blockNumber, existingEventIdentifier.logIndex) >
          (eventIdentifier.blockNumber, eventIdentifier.logIndex)
        ) {
          self->Js.Dict.set(chainKey, eventIdentifier)
        }
      | None => self->Js.Dict.set(chainKey, eventIdentifier)
      }
    }
  }

  let getFirstChangeEventIdentifierPerChain = async (sql, args: Args.t) => {
    let firstChangeEventIdentifierPerChain = FirstChangeEventIdentifierPerChain.make()

    await Utils.Array.awaitEach(Entities.allEntities, async entityMod => {
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

      let chainHistoryRows = try res->S.parseAnyOrRaiseWith(Entity.entityHistory.schemaRows) catch {
      | exn =>
        exn->ErrorHandling.mkLogAndRaise(
          ~msg=`Failed to parse entity history rows from db on getFirstChangeEntityHistoryPerChain`,
          ~logger=args->Args.getLogger(~entityName=Entity.name),
        )
      }

      chainHistoryRows->Belt.Array.forEach(chainHistoryRow => {
        let eventIdentifier: Types.eventIdentifier = {
          chainId: chainHistoryRow.current.chain_id,
          blockNumber: chainHistoryRow.current.block_number,
          logIndex: chainHistoryRow.current.log_index,
          blockTimestamp: chainHistoryRow.current.block_timestamp,
        }

        firstChangeEventIdentifierPerChain->FirstChangeEventIdentifierPerChain.set(~eventIdentifier)
      })
    })

    firstChangeEventIdentifierPerChain
  }

  let copyTableToEntityHistory = (sql, ~sourceTableName: Enums.EntityType.t): promise<unit> => {
    sql->Postgres.unsafe(`SELECT copy_table_to_entity_history('${(sourceTableName :> string)}');`)
  }

  let copyAllEntitiesToEntityHistory = sql => {
    sql->Postgres.beginSql(sql => {
      Enums.EntityType.variants->Belt.Array.map(entityType => {
        sql->copyTableToEntityHistory(~sourceTableName=entityType)
      })
    })
  }

  let hasRows = () => General.hasRows(sql, ~table=TablesStatic.EntityHistory.table)
}
