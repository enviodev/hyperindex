open Table

//shorthand for punning
let isPrimaryKey = true
let isNullable = true

// Tables the indexer keeps for itself. Postgres declares and writes them in the
// addon (`packages/cli/src/postgres/internal.rs`); what is here is what the
// rest of the indexer reads about them.

module Chains = {
  type field = [
    | #id
    | #ecosystem
    | #start_block
    | #end_block
    | #max_reorg_depth
    | #source_block
    | #first_event_block
    | #buffer_block
    | #progress_block
    | #progress_block_time
    | #ready_at
    | #events_processed
    | #_is_hyper_sync
    | #checkpoint_id
  ]

  let tableName = "envio_chains"

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
  type field = [
    | #id
    | #chain_id
    | #block_number
    | #block_hash
    | #events_processed
  ]

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
  // Postgres — there the diff is written straight to the entity table — but an
  // append-only sink resolves current state through the checkpoints, so without
  // one of these the diff sits above the frontier while the rows it supersedes
  // sit below it, and the orphaned values are what a reader sees.
  type diffCheckpoint = {
    chainId: ChainId.t,
    checkpointId: Internal.checkpointId,
    // Where the rollback left the chain. At or below its stored progress, so a
    // resume counts the row as covered rather than as something to trim back to.
    blockNumber: int,
  }

  // One definition per column, carrying what each storage needs: the field
  // itself, the type ClickHouse gives it where that differs from Postgres, and
  // where a batch — or a rollback diff — keeps the column's values.
  type column = {
    field: fieldOrDerived,
    clickHouseFieldType: fieldType,
    valuesOf: Batch.t => array<unknown>,
    diffValuesOf: array<diffCheckpoint> => array<unknown>,
  }

  // The chain leads the key: ids are only unique within a chain, and every
  // query that narrows to one chain reads a contiguous run of it.
  let columns: array<column> = [
    {
      field: mkField(
        (#chain_id: field :> string),
        ChainId,
        ~fieldSchema=ChainId.schema,
        ~isPrimaryKey,
      ),
      clickHouseFieldType: ChainId,
      valuesOf: batch =>
        batch.checkpointChainIds->(Utils.magic: array<ChainId.t> => array<unknown>),
      diffValuesOf: diffs =>
        diffs->Array.map(diff => diff.chainId->(Utils.magic: ChainId.t => unknown)),
    },
    {
      field: mkField((#id: field :> string), UInt64, ~fieldSchema=S.bigint, ~isPrimaryKey),
      clickHouseFieldType: UInt64,
      valuesOf: batch => batch.checkpointIds->(Utils.magic: array<bigint> => array<unknown>),
      diffValuesOf: diffs =>
        diffs->Array.map(diff => diff.checkpointId->(Utils.magic: bigint => unknown)),
    },
    {
      field: mkField((#block_number: field :> string), Int32, ~fieldSchema=S.int),
      clickHouseFieldType: Int32,
      valuesOf: batch => batch.checkpointBlockNumbers->(Utils.magic: array<int> => array<unknown>),
      diffValuesOf: diffs =>
        diffs->Array.map(diff => diff.blockNumber->(Utils.magic: int => unknown)),
    },
    {
      field: mkField(
        (#block_hash: field :> string),
        String,
        ~fieldSchema=S.null(S.string),
        ~isNullable,
      ),
      clickHouseFieldType: String,
      valuesOf: batch =>
        batch.checkpointBlockHashes->(Utils.magic: array<Null.t<string>> => array<unknown>),
      diffValuesOf: diffs =>
        diffs->Array.map(_ => Null.Null->(Utils.magic: Null.t<string> => unknown)),
    },
    {
      field: mkField((#events_processed: field :> string), Int32, ~fieldSchema=S.int),
      // A count of every event a chain has processed outgrows an Int32 where
      // Postgres keeps one, and ClickHouse has the id's width to spare.
      clickHouseFieldType: UInt64,
      valuesOf: batch =>
        batch.checkpointEventsProcessed->(Utils.magic: array<int> => array<unknown>),
      diffValuesOf: diffs => diffs->Array.map(_ => 0->(Utils.magic: int => unknown)),
    },
  ]

  let tableName = "envio_checkpoints"

  let table = mkTable(tableName, ~fields=columns->Array.map(({field}) => field))
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
