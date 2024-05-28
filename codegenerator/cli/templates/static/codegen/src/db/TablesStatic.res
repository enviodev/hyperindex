open Table
open Enums

//shorthand for punning
let isPrimaryKey = true
let isNullable = true

module EventSyncState = {
  type row = {
    chain_id: int,
    block_number: int,
    log_index: int,
    transaction_index: int,
    block_timestamp: int,
  }
  let tableName = "event_sync_state"

  let table = mkTable(
    "event_sync_state",
    ~fields=[
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("block_number", Integer),
      mkField("log_index", Integer),
      mkField("transaction_index", Integer),
      mkField("block_timestamp", Integer),
    ],
  )
}

module ChainMetadata = {
  type row = {
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
    timestamp_caught_up_to_head_or_endblock: Js.Date.t
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
      mkField(
        "timestamp_caught_up_to_head_or_endblock",
        Timestamp,
        // ~with="TIME ZONE NULL"//TODO enable with field
      ),
    ],
  )
}

module PersistedState = {
  type row = {
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
  type row = {
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

module RawEventsTable = {
  type row = {
    chain_id: int,
    event_id: float,
    block_number: int,
    log_index: int,
    transaction_index: int,
    transaction_hash: string,
    src_address: string,
    block_hash: string,
    block_timestamp: int,
    event_type: Enums.EventType.variants,
    params: Js.Json.t,
  }

  let table = mkTable(
    "raw_events",
    ~fields=[
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("event_id", Numeric, ~isPrimaryKey),
      mkField("block_number", Integer),
      mkField("log_index", Integer),
      mkField("transaction_index", Integer),
      mkField("transaction_hash", Text),
      mkField("src_address", Text),
      mkField("block_hash", Text),
      mkField("block_timestamp", Integer),
      mkField("event_type", Enum(EventType.enum.name)),
      mkField("params", Json),
      mkField("db_write_timestamp", Timestamp, ~default="CURRENT_TIMESTAMP"),
    ],
  )
}

module DynamicContractRegistryTable = {
  type row = {
    chain_id: int,
    event_id: Ethers.BigInt.t,
    block_timestamp: int,
    contract_address: string,
    contract_type: Enums.ContractType.variants,
  }
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

module EntityHistoryTable = {
  type row = {
    entity_id: string,
    block_timestamp: int,
    chain_id: int,
    block_number: int,
    log_index: int,
    entity_type: EntityType.variants,
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

module EntityHistoryFilterTable = {
  type row = {
    entity_id: option<string>,
    chain_id: int,
    old_val: option<Js.Json.t>,
    new_val: option<Js.Json.t>,
    block_number: int,
    block_timestamp: int,
    previous_block_number: option<int>,
    log_index: int,
    previous_log_index: option<int>,
    entity_type: EntityType.variants,
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
  RawEventsTable.table,
  DynamicContractRegistryTable.table,
  EntityHistoryTable.table,
  EntityHistoryFilterTable.table,
]
