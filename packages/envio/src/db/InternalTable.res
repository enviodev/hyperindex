open Table

//shorthand for punning
let isPrimaryKey = true
let isNullable = true

// Names and record types of the tables the indexer keeps for itself.

module Chains = {
  type metaFields = {
    @as("first_event_block")
    firstEventBlockNumber: Null.t<int>,
    @as("buffer_block") latestFetchedBlockNumber: int,
    @as("ready_at")
    timestampCaughtUpToHeadOrEndblock: Null.t<Date.t>,
    @as("_is_hyper_sync") isHyperSync: bool,
  }

  type progressedChain = {
    chainId: ChainId.t,
    progressBlockNumber: int,
    progressBlockTime: option<int>,
    sourceBlockNumber: int,
    totalEventsProcessed: float,
  }
}

module Checkpoints = {
  type t = {
    id: bigint,
    @as("chain_id")
    chainId: ChainId.t,
    @as("block_number")
    blockNumber: int,
    @as("block_hash")
    blockHash: Null.t<string>,
    @as("events_processed")
    eventsProcessed: int,
  }

  // Schema for parsing DB results where BIGINT columns come back as strings
  let dbSchema = S.object(s => {
    id: s.field("id", Utils.BigInt.schema),
    chainId: s.field("chain_id", ChainId.schema),
    blockNumber: s.field("block_number", S.int),
    blockHash: s.field(
      "block_hash",
      S.union([
        S.string->(Utils.magic: S.t<string> => S.t<Null.t<string>>),
        S.literal(%raw(`null`)),
      ]),
    ),
    eventsProcessed: s.field("events_processed", S.int),
  })

  // The checkpoint a rollback's diff rows are stamped with. It never reaches
  // Postgres — there the diff is written straight to the entity table — but
  // ClickHouse keeps the diff as history rows, and a checkpoint row for each,
  // which is what maps a history row back to its block.
  type diffCheckpoint = {
    chainId: ChainId.t,
    checkpointId: Internal.checkpointId,
    // Where the rollback left the chain. At or below its stored progress, so a
    // resume counts the row as covered rather than as something to trim back to.
    blockNumber: int,
  }

  let tableName = "envio_checkpoints"
}

module RawEvents = {
  type t = Internal.rawEvent

  let schema = S.schema((s): t => {
    chain_id: s.matches(ChainId.schema),
    event_id: s.matches(S.bigint),
    event_name: s.matches(S.string),
    contract_name: s.matches(S.string),
    block_number: s.matches(S.int),
    log_index: s.matches(S.int),
    src_address: s.matches(Address.schema),
    block_hash: s.matches(S.string),
    block_timestamp: s.matches(S.int),
    block_fields: s.matches(S.json(~validate=false)),
    transaction_fields: s.matches(S.json(~validate=false)),
    params: s.matches(S.json(~validate=false)),
  })

  let table = mkTable(
    "raw_events",
    ~fields=[
      mkField("chain_id", ChainId, ~fieldSchema=ChainId.schema),
      mkField("event_id", UInt64, ~fieldSchema=S.bigint),
      mkField("event_name", String, ~fieldSchema=S.string),
      mkField("contract_name", String, ~fieldSchema=S.string),
      mkField("block_number", Int32, ~fieldSchema=S.int),
      mkField("log_index", Int32, ~fieldSchema=S.int),
      mkField("src_address", String, ~fieldSchema=Address.schema),
      mkField("block_hash", String, ~fieldSchema=S.string),
      mkField("block_timestamp", Int32, ~fieldSchema=S.int),
      mkField("block_fields", Json, ~fieldSchema=S.json(~validate=false)),
      mkField("transaction_fields", Json, ~fieldSchema=S.json(~validate=false)),
      mkField("params", Json, ~fieldSchema=S.json(~validate=false)),
      mkField("serial", BigSerial, ~isNullable, ~isPrimaryKey, ~fieldSchema=S.null(S.bigint)),
    ],
  )
}

module Views = {
  let metaViewName = "_meta"
  let chainMetadataViewName = "chain_metadata"
}
