open Table

//shorthand for punning
let isPrimaryKey = true
let isNullable = true
let isIndex = true

module EventSyncState = {
  //Used unsafely in DbFunctions.res so just enforcing the naming here
  let blockTimestampFieldName = "block_timestamp"
  let blockNumberFieldName = "block_number"
  let logIndexFieldName = "log_index"
  let isPreRegisteringDynamicContractsFieldName = "is_pre_registering_dynamic_contracts"

  @genType
  type t = {
    @as("chain_id") chainId: int,
    @as("block_number") blockNumber: int,
    @as("log_index") logIndex: int,
    @as("block_timestamp") blockTimestamp: int,
  }

  let table = mkTable(
    PgStorage.eventSyncStateTableName,
    ~fields=[
      mkField("chain_id", Integer, ~fieldSchema=S.int, ~isPrimaryKey),
      mkField(blockNumberFieldName, Integer, ~fieldSchema=S.int),
      mkField(logIndexFieldName, Integer, ~fieldSchema=S.int),
      mkField(blockTimestampFieldName, Integer, ~fieldSchema=S.int),
      // Keep it in case Hosted Service relies on it to prevent a breaking changes
      mkField(
        isPreRegisteringDynamicContractsFieldName,
        Boolean,
        ~default="false",
        ~fieldSchema=S.bool,
      ),
    ],
  )

  //We need to update values here not delet the rows, since restarting without a row
  //has a different behaviour to restarting with an initialised row with zero values
  let resetCurrentCurrentSyncStateQuery = `UPDATE "${Env.Db.publicSchema}"."${table.tableName}"
    SET ${blockNumberFieldName} = 0, 
        ${logIndexFieldName} = 0, 
        ${blockTimestampFieldName} = 0, 
        ${isPreRegisteringDynamicContractsFieldName} = false;`
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
      mkField("chain_id", Integer, ~fieldSchema=S.int, ~isPrimaryKey),
      mkField("start_block", Integer, ~fieldSchema=S.int),
      mkField("end_block", Integer, ~fieldSchema=S.null(S.int), ~isNullable),
      mkField("block_height", Integer, ~fieldSchema=S.int),
      mkField("first_event_block_number", Integer, ~fieldSchema=S.null(S.int), ~isNullable),
      mkField("latest_processed_block", Integer, ~fieldSchema=S.null(S.int), ~isNullable),
      mkField("num_events_processed", Integer, ~fieldSchema=S.null(S.int), ~isNullable),
      mkField("is_hyper_sync", Boolean, ~fieldSchema=S.bool),
      mkField("num_batches_fetched", Integer, ~fieldSchema=S.int),
      mkField("latest_fetched_block_number", Integer, ~fieldSchema=S.int),
      // Used to show how much time historical sync has taken, so we need a timezone here (TUI and Hosted Service)
      mkField(
        "timestamp_caught_up_to_head_or_endblock",
        TimestampWithNullTimezone,
        ~fieldSchema=S.null(Utils.Schema.dbDate),
        ~isNullable,
      ),
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
      mkField("id", Serial, ~fieldSchema=S.int, ~isPrimaryKey),
      mkField("envio_version", Text, ~fieldSchema=S.string),
      mkField("config_hash", Text, ~fieldSchema=S.string),
      mkField("schema_hash", Text, ~fieldSchema=S.string),
      mkField("handler_files_hash", Text, ~fieldSchema=S.string),
      mkField("abi_files_hash", Text, ~fieldSchema=S.string),
    ],
  )
}

module EndOfBlockRangeScannedData = {
  @genType
  type t = {
    chain_id: int,
    block_number: int,
    block_hash: string,
  }

  let table = mkTable(
    "end_of_block_range_scanned_data",
    ~fields=[
      mkField("chain_id", Integer, ~fieldSchema=S.int, ~isPrimaryKey),
      mkField("block_number", Integer, ~fieldSchema=S.int, ~isPrimaryKey),
      mkField("block_hash", Text, ~fieldSchema=S.string),
    ],
  )
}

module RawEvents = {
  @genType
  type t = {
    @as("chain_id") chainId: int,
    @as("event_id") eventId: bigint,
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

  let schema = S.schema(s => {
    chainId: s.matches(S.int),
    eventId: s.matches(S.bigint),
    eventName: s.matches(S.string),
    contractName: s.matches(S.string),
    blockNumber: s.matches(S.int),
    logIndex: s.matches(S.int),
    srcAddress: s.matches(Address.schema),
    blockHash: s.matches(S.string),
    blockTimestamp: s.matches(S.int),
    blockFields: s.matches(S.json(~validate=false)),
    transactionFields: s.matches(S.json(~validate=false)),
    params: s.matches(S.json(~validate=false)),
  })

  let table = mkTable(
    PgStorage.rawEventsTableName,
    ~fields=[
      mkField("chain_id", Integer, ~fieldSchema=S.int),
      mkField("event_id", Numeric, ~fieldSchema=S.bigint),
      mkField("event_name", Text, ~fieldSchema=S.string),
      mkField("contract_name", Text, ~fieldSchema=S.string),
      mkField("block_number", Integer, ~fieldSchema=S.int),
      mkField("log_index", Integer, ~fieldSchema=S.int),
      mkField("src_address", Text, ~fieldSchema=Address.schema),
      mkField("block_hash", Text, ~fieldSchema=S.string),
      mkField("block_timestamp", Integer, ~fieldSchema=S.int),
      mkField("block_fields", JsonB, ~fieldSchema=S.json(~validate=false)),
      mkField("transaction_fields", JsonB, ~fieldSchema=S.json(~validate=false)),
      mkField("params", JsonB, ~fieldSchema=S.json(~validate=false)),
      mkField(
        "db_write_timestamp",
        TimestampWithoutTimezone,
        ~default="CURRENT_TIMESTAMP",
        ~fieldSchema=S.int,
      ),
      mkField("serial", Serial, ~isNullable, ~isPrimaryKey, ~fieldSchema=S.null(S.int)),
    ],
  )
}

module DynamicContractRegistry = {
  let name = Enums.EntityType.DynamicContractRegistry

  let makeId = (~chainId, ~contractAddress) => {
    chainId->Belt.Int.toString ++ "-" ++ contractAddress->Address.toString
  }

  @genType
  type t = {
    id: string,
    @as("chain_id") chainId: int,
    @as("registering_event_block_number") registeringEventBlockNumber: int,
    @as("registering_event_log_index") registeringEventLogIndex: int,
    @as("registering_event_block_timestamp") registeringEventBlockTimestamp: int,
    @as("registering_event_contract_name") registeringEventContractName: string,
    @as("registering_event_name") registeringEventName: string,
    @as("registering_event_src_address") registeringEventSrcAddress: Address.t,
    @as("contract_address") contractAddress: Address.t,
    @as("contract_type") contractType: Enums.ContractType.t,
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
    contractType: s.matches(Enums.ContractType.config.schema),
  })

  let rowsSchema = S.array(schema)

  let table = mkTable(
    "dynamic_contract_registry",
    ~fields=[
      mkField("id", Text, ~isPrimaryKey, ~fieldSchema=S.string),
      mkField("chain_id", Integer, ~fieldSchema=S.int),
      mkField("registering_event_block_number", Integer, ~fieldSchema=S.int),
      mkField("registering_event_log_index", Integer, ~fieldSchema=S.int),
      mkField("registering_event_block_timestamp", Integer, ~fieldSchema=S.int),
      mkField("registering_event_contract_name", Text, ~fieldSchema=S.string),
      mkField("registering_event_name", Text, ~fieldSchema=S.string),
      mkField("registering_event_src_address", Text, ~fieldSchema=Address.schema),
      mkField("contract_address", Text, ~fieldSchema=Address.schema),
      mkField(
        "contract_type",
        Custom(Enums.ContractType.config.name),
        ~fieldSchema=Enums.ContractType.config.schema,
      ),
    ],
  )

  let entityHistory = table->EntityHistory.fromTable(~pgSchema=Env.Db.publicSchema, ~schema)

  external castToInternal: t => Internal.entity = "%identity"
}
