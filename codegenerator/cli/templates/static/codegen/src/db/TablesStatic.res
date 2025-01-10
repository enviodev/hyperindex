open Table

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
    @as("is_pre_registering_dynamic_contracts") isPreRegisteringDynamicContracts: bool,
  }

  let table = mkTable(
    "event_sync_state",
    ~fields=[
      mkField("chain_id", Integer, ~isPrimaryKey),
      mkField("block_number", Integer),
      mkField("log_index", Integer),
      mkField("block_timestamp", Integer),
      mkField("is_pre_registering_dynamic_contracts", Boolean),
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
      // Used to show how much time historical sync has taken, so we need a timezone here (TUI and Hosted Service)
      mkField("timestamp_caught_up_to_head_or_endblock", TimestampWithNullTimezone, ~isNullable),
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
    @as("event_name") eventName: string,
    @as("contract_name") contractName: string,
    @as("block_number") blockNumber: int,
    @as("log_index") logIndex: int,
    @as("src_address") srcAddress: Address.t,
    @as("block_hash") blockHash: string,
    @as("block_timestamp") blockTimestamp: int,
    @as("block_fields") blockFields: Js.Json.t,
    @as("transaction_fields") transactionFields: Js.Json.t,
    params: Js.Json.t,
  }

  let table = mkTable(
    "raw_events",
    ~fields=[
      mkField("chain_id", Integer),
      mkField("event_id", Numeric),
      mkField("event_name", Text),
      mkField("contract_name", Text),
      mkField("block_number", Integer),
      mkField("log_index", Integer),
      mkField("src_address", Text),
      mkField("block_hash", Text),
      mkField("block_timestamp", Integer),
      mkField("block_fields", JsonB),
      mkField("transaction_fields", JsonB),
      mkField("params", JsonB),
      mkField("db_write_timestamp", TimestampWithoutTimezone, ~default="CURRENT_TIMESTAMP"),
      mkField("serial", Serial, ~isNullable, ~isPrimaryKey),
    ],
  )
}

module DynamicContractRegistry = {
  let name = Enums.EntityType.DynamicContractRegistry

  @genType
  type t = {
    id: string,
    @as("chain_id") chainId: int,
    @as("registering_event_block_number") registeringEventBlockNumber: int,
    @as("registering_event_log_index") registeringEventLogIndex: int,
    @as("registering_event_name") registeringEventName: string,
    @as("registering_event_contract_name") registeringEventContractName: string,
    @as("registering_event_src_address") registeringEventSrcAddress: Address.t,
    @as("registering_event_block_timestamp") registeringEventBlockTimestamp: int,
    @as("contract_address") contractAddress: Address.t,
    @as("contract_type") contractType: Enums.ContractType.t,
    @as("is_pre_registered") isPreRegistered: bool,
  }

  let schema = S.schema(s => {
    id: s.matches(S.string),
    chainId: s.matches(S.int),
    registeringEventBlockNumber: s.matches(S.int),
    registeringEventLogIndex: s.matches(S.int),
    registeringEventContractName: s.matches(S.string),
    registeringEventName: s.matches(S.string),
    registeringEventSrcAddress: s.matches(Address.schema),
    registeringEventBlockTimestamp: s.matches(S.int),
    contractAddress: s.matches(Address.schema),
    contractType: s.matches(Enums.ContractType.enum.schema),
    isPreRegistered: s.matches(S.bool),
  })

  let rowsSchema = S.array(schema)

  let table = mkTable(
    "dynamic_contract_registry",
    ~fields=[
      mkField("id", Text, ~isPrimaryKey),
      mkField("chain_id", Integer),
      mkField("registering_event_block_number", Integer),
      mkField("registering_event_log_index", Integer),
      mkField("registering_event_block_timestamp", Integer),
      mkField("registering_event_contract_name", Text),
      mkField("registering_event_name", Text),
      mkField("registering_event_src_address", Text),
      mkField("contract_address", Text),
      mkField("contract_type", Custom(Enums.ContractType.enum.name)),
      mkField("is_pre_registered", Boolean),
    ],
  )

  let entityHistory = table->EntityHistory.fromTable(~schema)
}
