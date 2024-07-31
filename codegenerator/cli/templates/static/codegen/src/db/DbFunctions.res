let config: Postgres.poolConfig = Config.db
let sql = Postgres.makeSql(~config)

type chainId = int
type eventId = string
type blockNumberRow = {@as("block_number") blockNumber: int}

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
    ~contractAddresses: array<Ethers.ethAddress>,
  ) => promise<array<TablesStatic.RawEvents.t>> = "getRawEventsPageGtOrEqEventId"

  @module("./DbFunctionsImplementation.js")
  external getRawEventsPageWithinEventIdRangeInclusive: (
    Postgres.sql,
    ~chainId: chainId,
    ~fromEventIdInclusive: bigint,
    ~toEventIdInclusive: bigint,
    ~limit: int,
    ~contractAddresses: array<Ethers.ethAddress>,
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
  type contractAddress = Ethers.ethAddress
  type dynamicContractRegistryRowId = (chainId, contractAddress)
  @module("./DbFunctionsImplementation.js")
  external batchSet: (
    Postgres.sql,
    array<TablesStatic.DynamicContractRegistry.t>,
  ) => promise<unit> = "batchSetDynamicContractRegistry"

  @module("./DbFunctionsImplementation.js")
  external batchDelete: (Postgres.sql, array<dynamicContractRegistryRowId>) => promise<unit> =
    "batchDeleteDynamicContractRegistry"

  @module("./DbFunctionsImplementation.js")
  external readEntities: (
    Postgres.sql,
    array<dynamicContractRegistryRowId>,
  ) => promise<array<Js.Json.t>> = "readDynamicContractRegistryEntities"

  type contractTypeAndAddress = TablesStatic.DynamicContractRegistry.t

  let contractTypeAndAddressSchema = TablesStatic.DynamicContractRegistry.schema
  let contractTypeAndAddressArraySchema = S.array(contractTypeAndAddressSchema)

  ///Returns an array with 1 block number (the highest processed on the given chainId)
  @module("./DbFunctionsImplementation.js")
  external readDynamicContractsOnChainIdAtOrBeforeBlockRaw: (
    Postgres.sql,
    ~chainId: chainId,
    ~startBlock: int,
  ) => promise<Js.Json.t> = "readDynamicContractsOnChainIdAtOrBeforeBlock"

  let readDynamicContractsOnChainIdAtOrBeforeBlock = (sql, ~chainId, ~startBlock) =>
    readDynamicContractsOnChainIdAtOrBeforeBlockRaw(
      sql,
      ~chainId,
      ~startBlock,
    )->Promise.thenResolve(json => json->S.parseOrRaiseWith(contractTypeAndAddressArraySchema))

  @module("./DbFunctionsImplementation.js")
  external deleteAllDynamicContractRegistrationsAfterEventIdentifier: (
    Postgres.sql,
    ~eventIdentifier: Types.eventIdentifier,
  ) => promise<unit> = "deleteAllDynamicContractRegistrationsAfterEventIdentifier"
}

type entityHistoryItem = {
  block_timestamp: int,
  chain_id: int,
  block_number: int,
  log_index: int,
  previous_block_timestamp: option<int>,
  previous_chain_id: option<int>,
  previous_block_number: option<int>,
  previous_log_index: option<int>,
  params: option<Js.Json.t>,
  entity_type: string,
  entity_id: string,
}

let entityHistoryItemSchema = S.object(s => {
  block_timestamp: s.field("block_timestamp", S.int),
  chain_id: s.field("chain_id", S.int),
  block_number: s.field("block_number", S.int),
  log_index: s.field("log_index", S.int),
  previous_block_timestamp: s.field("previous_block_timestamp", S.null(S.int)),
  previous_chain_id: s.field("previous_chain_id", S.null(S.int)),
  previous_block_number: s.field("previous_block_number", S.null(S.int)),
  previous_log_index: s.field("previous_log_index", S.null(S.int)),
  params: s.field("params", S.null(S.json(~validate=false))),
  entity_type: s.field("entity_type", S.string),
  entity_id: s.field("entity_id", S.string),
})

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

  let batchSet = (sql, ~entityHistoriesToSet) => {
    //Encode null for for the with prev types so that it's not undefined
    batchSetInternal(
      sql,
      ~entityHistoriesToSet=entityHistoriesToSet->Belt.Array.map(v =>
        v->S.serializeOrRaiseWith(entityHistoryItemSchema)
      ),
    )
  }

  @module("./DbFunctionsImplementation.js")
  external deleteAllEntityHistoryAfterEventIdentifier: (
    Postgres.sql,
    ~eventIdentifier: Types.eventIdentifier,
  ) => promise<unit> = "deleteAllEntityHistoryAfterEventIdentifier"

  type rollbackDiffResponseRaw = {
    entity_type: Enums.EntityType.t,
    entity_id: string,
    chain_id: option<int>,
    block_timestamp: option<int>,
    block_number: option<int>,
    log_index: option<int>,
    val: option<Js.Json.t>,
  }

  let rollbackDiffResponseRawSchema = S.object(s => {
    entity_type: s.field("entity_type", Enums.EntityType.schema),
    entity_id: s.field("entity_id", S.string),
    chain_id: s.field("chain_id", S.null(S.int)),
    block_timestamp: s.field("block_timestamp", S.null(S.int)),
    block_number: s.field("block_number", S.null(S.int)),
    log_index: s.field("log_index", S.null(S.int)),
    val: s.field("val", S.null(S.json(~validate=false))),
  })

  type previousEntity = {
    eventIdentifier: Types.eventIdentifier,
    entity: Entities.entity,
  }

  type rollbackDiffResponse = {
    entityType: Enums.EntityType.t,
    entityId: string,
    previousEntity: option<previousEntity>,
  }

  let rollbackDiffResponse_decode = (json: Js.Json.t) => {
    json
    ->S.parseWith(rollbackDiffResponseRawSchema)
    ->Belt.Result.flatMap(raw => {
      switch raw {
      | {
          val: Some(val),
          chain_id: Some(chainId),
          block_number: Some(blockNumber),
          block_timestamp: Some(blockTimestamp),
          log_index: Some(logIndex),
          entity_type,
        } =>
        Entities.getEntityParamsDecoder(entity_type)(val)->Belt.Result.map(entity => {
          let eventIdentifier: Types.eventIdentifier = {
            chainId,
            blockTimestamp,
            blockNumber,
            logIndex,
          }

          Some({entity, eventIdentifier})
        })
      | _ => Ok(None)
      }->Belt.Result.map(previousEntity => {
        entityType: raw.entity_type,
        entityId: raw.entity_id,
        previousEntity,
      })
    })
  }

  let rollbackDiffResponseArr_decode = (jsonArr: array<Js.Json.t>) => {
    jsonArr->Belt.Array.map(rollbackDiffResponse_decode)->Utils.mapArrayOfResults
  }

  @module("./DbFunctionsImplementation.js")
  external getRollbackDiffInternal: (
    Postgres.sql,
    ~blockTimestamp: int,
    ~chainId: int,
    ~blockNumber: int,
  ) => promise<array<Js.Json.t>> = "getRollbackDiff"

  let getRollbackDiff = (sql, ~blockTimestamp: int, ~chainId: int, ~blockNumber: int) =>
    getRollbackDiffInternal(sql, ~blockTimestamp, ~chainId, ~blockNumber)->Promise.thenResolve(
      rollbackDiffResponseArr_decode,
    )
}
