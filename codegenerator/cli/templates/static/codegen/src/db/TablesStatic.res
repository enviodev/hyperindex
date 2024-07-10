open Table
open Enums

//shorthand for punning
let isPrimaryKey = true
let isNullable = true
let isIndex = true

module EventSyncState = {
  @genType
  type t = {
    @as("chain_id") chainId: int,
    @as("block_number") blockNumber: int,
    @as("log_index") logIndex: int,
    @as("block_timestamp") blockTimestamp: int,
  }

  let table = mkTable(
    "event_sync_state",
    ~fields=[
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("block_number", Integer),
      mkField("log_index", Integer),
      mkField("block_timestamp", Integer),
    ],
  )
}

module ChainMetadata = {
  @genType
  type t = {
    chain_id: int,
    start_block: int,
    end_block: option<int>,
    block_height: int,
    first_event_block_number: option<int>,
    latest_processed_block: option<int>,
    num_events_processed: option<int>,
    is_hyper_sync: bool,
    num_batches_fetched: int,
    latest_fetched_block_number: int,
    timestamp_caught_up_to_head_or_endblock: Js.Date.t,
  }

  let table = mkTable(
    "chain_metadata",
    ~fields=[
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("start_block", Integer),
      mkField("end_block", Integer, ~isNullable),
      mkField("block_height", Integer),
      mkField("first_event_block_number", Integer, ~isNullable),
      mkField("latest_processed_block", Integer, ~isNullable),
      mkField("num_events_processed", Integer, ~isNullable),
      mkField("is_hyper_sync", Boolean),
      mkField("num_batches_fetched", Integer),
      mkField("latest_fetched_block_number", Integer),
      mkField("timestamp_caught_up_to_head_or_endblock", TimestampWithTZNull, ~isNullable),
    ],
  )
}

module PersistedState = {
  @genType
  type t = {
    id: int,
    envio_version: string,
    config_hash: string,
    schema_hash: string,
    handler_files_hash: string,
    abi_files_hash: string,
  }

  let table = mkTable(
    "persisted_state",
    ~fields=[
      mkField("id", Serial, ~isPrimaryKey),
      mkField("envio_version", Text),
      mkField("config_hash", Text),
      mkField("schema_hash", Text),
      mkField("handler_files_hash", Text),
      mkField("abi_files_hash", Text),
    ],
  )
}

module EndOfBlockRangeScannedData = {
  @genType
  type t = {
    chain_id: int,
    block_timestamp: int,
    block_number: int,
    block_hash: string,
  }

  let table = mkTable(
    "end_of_block_range_scanned_data",
    ~fields=[
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("block_timestamp", Integer),
      mkField("block_number", Integer, ~isPrimaryKey),
      mkField("block_hash", Text),
    ],
  )
}

module RawEvents = {
  @genType
  type t = {
    @as("chain_id") chainId: int,
    @as("event_id") eventId: string,
    @as("block_number") blockNumber: int,
    @as("log_index") logIndex: int,
    @as("src_address") srcAddress: Ethers.ethAddress,
    @as("block_hash") blockHash: string,
    @as("block_timestamp") blockTimestamp: int,
    @as("event_type") eventType: Enums.EventType.t,
    @as("block_fields") blockFields: Js.Json.t,
    @as("transaction_fields") transactionFields: Js.Json.t,
    params: Js.Json.t,
  }

  let table = mkTable(
    "raw_events",
    ~fields=[
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("event_id", Numeric, ~isPrimaryKey),
      mkField("block_number", Integer),
      mkField("log_index", Integer),
      mkField("src_address", Text),
      mkField("block_hash", Text),
      mkField("block_timestamp", Integer),
      mkField("event_type", Enum(EventType.enum.name)),
      mkField("block_fields", Json),
      mkField("transaction_fields", Json),
      mkField("params", Json),
      mkField("db_write_timestamp", Timestamp, ~default="CURRENT_TIMESTAMP"),
    ],
  )
}

module DynamicContractRegistry = {
  @genType
  type t = {
    @as("chain_id") chainId: int,
    @as("event_id") eventId: bigint,
    @as("block_timestamp") blockTimestamp: int,
    @as("contract_address") contractAddress: Ethers.ethAddress,
    @as("contract_type") contractType: Enums.ContractType.t,
  }

  let schema = S.object((. s) => {
    chainId: s.field("chain_id", S.int),
    eventId: s.field("event_id", BigInt.schema),
    blockTimestamp: s.field("block_timestamp", S.int),
    contractAddress: s.field("contract_address", Ethers.ethAddressSchema),
    contractType: s.field("contract_type", Enums.ContractType.schema),
  })

  let table = mkTable(
    "dynamic_contract_registry",
    ~fields=[
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("event_id", Numeric),
      mkField("block_timestamp", Integer),
      mkField("contract_address", Text, ~isPrimaryKey),
      mkField("contract_type", Enum(ContractType.enum.name)),
    ],
  )
}

module EntityHistory = {
  @genType
  type t = {
    entity_id: string,
    block_timestamp: int,
    chain_id: int,
    block_number: int,
    log_index: int,
    entity_type: EntityType.t,
    params: option<Js.Json.t>,
    previous_block_timestamp: option<int>,
    previous_chain_id: option<int>,
    previous_block_number: option<int>,
    previous_log_index: option<int>,
  }

  let table = mkTable(
    "entity_history",
    ~fields=[
      mkField("entity_id", Text, ~isPrimaryKey),
      mkField("block_timestamp", Integer, ~isPrimaryKey),
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("block_number", Integer, ~isPrimaryKey),
      mkField("log_index", Integer, ~isPrimaryKey),
      mkField("entity_type", Enum(EntityType.enum.name), ~isPrimaryKey),
      mkField("params", Json, ~isNullable),
      mkField("previous_block_timestamp", Integer, ~isNullable),
      mkField("previous_chain_id", Integer, ~isNullable),
      mkField("previous_block_number", Integer, ~isNullable),
      mkField("previous_log_index", Integer, ~isNullable),
    ],
    ~compositeIndices=[["entity_type", "entity_id", "block_timestamp"]],
  )
}

module EntityHistoryFilter = {
  @genType
  type t = {
    entity_id: option<string>,
    chain_id: int,
    old_val: option<Js.Json.t>,
    new_val: option<Js.Json.t>,
    block_number: int,
    block_timestamp: int,
    previous_block_number: option<int>,
    log_index: int,
    previous_log_index: option<int>,
    entity_type: EntityType.t,
  }

  // This table is purely for the sake of viewing the diffs generated by the postgres function. It will never be written to during the application.
  let table = mkTable(
    "entity_history_filter",
    ~fields=[
      // NULL for an `entity_id` means that the entity was deleted.
      mkField("entity_id", Text, ~isPrimaryKey),
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("old_val", Json, ~isNullable),
      mkField("new_val", Json, ~isNullable),
      mkField("block_number", Integer, ~isPrimaryKey),
      mkField("block_timestamp", Integer, ~isPrimaryKey),
      mkField("previous_block_number", Integer, ~isNullable),
      mkField("log_index", Integer, ~isPrimaryKey),
      mkField("previous_log_index", Integer, ~isNullable, ~isPrimaryKey),
      mkField("entity_type", Enum(EntityType.enum.name), ~isPrimaryKey),
    ],
  )
}

let allTables: array<table> = [
  EventSyncState.table,
  ChainMetadata.table,
  PersistedState.table,
  EndOfBlockRangeScannedData.table,
  RawEvents.table,
  DynamicContractRegistry.table,
  EntityHistory.table,
  EntityHistoryFilter.table,
]

