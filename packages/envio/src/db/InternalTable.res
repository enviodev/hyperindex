open Table

//shorthand for punning
let isPrimaryKey = true
let isNullable = true
let isIndex = true

module EnvioAddresses = Config.EnvioAddresses

module Chains = {
  type progressFields = [
    | #progress_block
    | #events_processed
    | #source_block
  ]

  type field = [
    | progressFields
    | #id
    | #start_block
    | #end_block
    | #max_reorg_depth
    | #source_block
    | #first_event_block
    | #buffer_block
    | #ready_at
    | #_is_hyper_sync
  ]

  let fields: array<field> = [
    #id,
    #start_block,
    #end_block,
    #max_reorg_depth,
    #source_block,
    #first_event_block,
    #buffer_block,
    #progress_block,
    #ready_at,
    #events_processed,
    #_is_hyper_sync,
  ]

  type metaFields = {
    @as("first_event_block")
    firstEventBlockNumber: Null.t<
      // Push id first (for WHERE clause)

      // Then push all updateable field values (for SET clause)
      int,
    >,
    @as("buffer_block") latestFetchedBlockNumber: int,
    @as("ready_at")
    timestampCaughtUpToHeadOrEndblock: Null.t<Date.t>,
    @as("_is_hyper_sync") isHyperSync: bool,
  }

  type t = {
    @as("id") id: int,
    @as("start_block") startBlock: int,
    @as("end_block") endBlock: Null.t<int>,
    @as("max_reorg_depth") maxReorgDepth: int,
    @as("source_block") blockHeight: int,
    @as("progress_block") progressBlockNumber: int,
    @as("events_processed") numEventsProcessed: float,
    ...metaFields,
  }

  let table = mkTable(
    "envio_chains",
    ~fields=[
      mkField((#id: field :> string), Int32, ~fieldSchema=S.int, ~isPrimaryKey),
      // Values populated from config
      mkField((#start_block: field :> string), Int32, ~fieldSchema=S.int),
      mkField((#end_block: field :> string), Int32, ~fieldSchema=S.null(S.int), ~isNullable),
      mkField((#max_reorg_depth: field :> string), Int32, ~fieldSchema=S.int),
      // Block number of the latest block that was fetched from the source
      mkField((#buffer_block: field :> string), Int32, ~fieldSchema=S.int),
      // Block number of the currently active source
      mkField((#source_block: field :> string), Int32, ~fieldSchema=S.int),
      // Block number of the first event that was processed for this chain
      mkField(
        (#first_event_block: field :> string),
        Int32,
        ~fieldSchema=S.null(S.int),
        ~isNullable,
      ),
      // Used to show how much time historical sync has taken, so we need a timezone here (TUI and Hosted Service)
      // null during historical sync, set to current time when sync is complete
      mkField(
        (#ready_at: field :> string),
        Date,
        ~fieldSchema=S.null(Utils.Schema.dbDate),
        ~isNullable,
      ),
      mkField((#events_processed: field :> string), UInt52, ~fieldSchema=S.float),
      // TODO: In the future it should reference a table with sources
      mkField((#_is_hyper_sync: field :> string), Boolean, ~fieldSchema=S.bool),
      // Fully processed block number
      mkField((#progress_block: field :> string), Int32, ~fieldSchema=S.int),
    ],
  )

  let initialFromConfig = (chainConfig: Config.chain) => {
    {
      id: chainConfig.id,
      startBlock: chainConfig.startBlock,
      endBlock: chainConfig.endBlock->Null.fromOption,
      maxReorgDepth: chainConfig.maxReorgDepth,
      blockHeight: 0,
      firstEventBlockNumber: Null.null,
      latestFetchedBlockNumber: -1,
      timestampCaughtUpToHeadOrEndblock: Null.null,
      progressBlockNumber: -1,
      isHyperSync: false,
      numEventsProcessed: 0.,
    }
  }

  let makeInitialValuesQuery = (~pgSchema, ~chainConfigs: array<Config.chain>) => {
    if chainConfigs->Array.length === 0 {
      None
    } else {
      // Create column names list
      let columnNames = fields->Array.map(field => `"${(field :> string)}"`)

      // Create VALUES rows for each chain config
      let valuesRows = chainConfigs->Array.map(chainConfig => {
        let initialValues = initialFromConfig(chainConfig)
        let values = fields->Array.map((field: field) => {
          let value = initialValues->(Utils.magic: t => dict<unknown>)->Dict.get((field :> string))
          switch typeof(value) {
          | #object => "NULL"
          | #number => value->(Utils.magic: option<unknown> => int)->Int.toString
          | #bigint => value->(Utils.magic: option<unknown> => bigint)->BigInt.toString
          | #boolean => value->(Utils.magic: option<unknown> => bool) ? "true" : "false"
          | _ => JsError.throwWithMessage("Invalid envio_chains value type")
          }
        })

        `(${values->Array.joinUnsafe(", ")})`
      })

      Some(
        `INSERT INTO "${pgSchema}"."${table.tableName}" (${columnNames->Array.joinUnsafe(", ")})
VALUES ${valuesRows->Array.joinUnsafe(",\n       ")};`,
      )
    }
  }

  // Fields that can be updated outside of the batch transaction
  let metaFields: array<field> = [#buffer_block, #first_event_block, #ready_at, #_is_hyper_sync]

  let makeMetaFieldsUpdateQuery = (~pgSchema) => {
    // Generate SET clauses with parameter placeholders
    let setClauses = Array.mapWithIndex(metaFields, (field, index) => {
      let fieldName = (field :> string)
      let paramIndex = index + 2 // +2 because $1 is for id in WHERE clause
      `"${fieldName}" = $${Int.toString(paramIndex)}`
    })

    `UPDATE "${pgSchema}"."${table.tableName}"
SET ${setClauses->Array.joinUnsafe(",\n    ")}
WHERE "${(#id: field :> string)}" = $1;`
  }

  type rawInitialState = {
    id: int,
    startBlock: int,
    endBlock: Null.t<int>,
    maxReorgDepth: int,
    firstEventBlockNumber: Null.t<int>,
    timestampCaughtUpToHeadOrEndblock: Null.t<Date.t>,
    numEventsProcessed: float,
    progressBlockNumber: int,
    indexingAddresses: array<Internal.indexingAddress>,
    sourceBlockNumber: int,
  }

  let makeGetInitialStateQuery = (~pgSchema) => {
    `SELECT "${(#id: field :> string)}" as "id",
"${(#start_block: field :> string)}" as "startBlock",
"${(#end_block: field :> string)}" as "endBlock",
"${(#max_reorg_depth: field :> string)}" as "maxReorgDepth",
"${(#first_event_block: field :> string)}" as "firstEventBlockNumber",
"${(#ready_at: field :> string)}" as "timestampCaughtUpToHeadOrEndblock",
"${(#events_processed: field :> string)}"::float8 as "numEventsProcessed",
"${(#progress_block: field :> string)}" as "progressBlockNumber",
"${(#source_block: field :> string)}" as "sourceBlockNumber"
FROM "${pgSchema}"."${table.tableName}";`
  }

  type rawIndexingAddress = {
    chainId: int,
    address: Address.t,
    contractName: string,
    registrationBlock: int,
  }

  // Addresses are read as plain rows rather than aggregated per chain with
  // json_agg: a single chain's aggregate can exceed V8's max string length
  // (postgres.js decodes the column with Buffer.toString and throws
  // ERR_STRING_TOO_LONG). Grouping happens in JS instead — see getInitialState.
  let makeGetIndexingAddressesQuery = (~pgSchema) => {
    // envio_addresses.id is a composite "{chainId}-{address}" string produced by
    // Config.EnvioAddresses.makeId; extract the address by taking everything
    // after the first '-'. Keep in sync with makeId / getAddress.
    `SELECT "chain_id" as "chainId",
SUBSTRING("id" FROM POSITION('-' IN "id") + 1) as "address",
"contract_name" as "contractName",
"registration_block" as "registrationBlock"
FROM "${pgSchema}"."${EnvioAddresses.table.tableName}";`
  }

  let getInitialState = async (sql, ~pgSchema) => {
    let (rawInitialStates, rawIndexingAddresses) = await Promise.all2((
      sql
      ->Postgres.unsafe(makeGetInitialStateQuery(~pgSchema))
      ->(Utils.magic: promise<array<unknown>> => promise<array<rawInitialState>>),
      sql
      ->Postgres.unsafe(makeGetIndexingAddressesQuery(~pgSchema))
      ->(Utils.magic: promise<array<unknown>> => promise<array<rawIndexingAddress>>),
    ))

    let indexingAddressesByChainId = Dict.make()
    rawIndexingAddresses->Array.forEach(row => {
      let key = row.chainId->Int.toString
      let addresses = switch indexingAddressesByChainId->Dict.get(key) {
      | Some(addresses) => addresses
      | None =>
        let addresses: array<Internal.indexingAddress> = []
        indexingAddressesByChainId->Dict.set(key, addresses)
        addresses
      }
      addresses
      ->Array.push({
        address: row.address,
        contractName: row.contractName,
        registrationBlock: row.registrationBlock,
      })
      ->ignore
    })

    rawInitialStates->Array.map(rawInitialState => {
      ...rawInitialState,
      indexingAddresses: indexingAddressesByChainId
      ->Dict.get(rawInitialState.id->Int.toString)
      ->Option.getOr([]),
    })
  }

  let progressFields: array<progressFields> = [#progress_block, #events_processed, #source_block]

  let makeProgressFieldsUpdateQuery = (~pgSchema) => {
    let setClauses = Array.mapWithIndex(progressFields, (field, index) => {
      let fieldName = (field :> string)
      let paramIndex = index + 2 // +2 because $1 is for id in WHERE clause
      `"${fieldName}" = $${Int.toString(paramIndex)}`
    })

    `UPDATE "${pgSchema}"."${table.tableName}"
SET ${setClauses->Array.joinUnsafe(",\n    ")}
WHERE "id" = $1;`
  }

  let setMeta = (sql, ~pgSchema, ~chainsData: dict<metaFields>) => {
    let query = makeMetaFieldsUpdateQuery(~pgSchema)

    let promises = []

    chainsData->Utils.Dict.forEachWithKey((data, chainId) => {
      let params = []

      // Push id first (for WHERE clause)
      params->Array.push(chainId->(Utils.magic: string => unknown))->ignore

      // Then push all updateable field values (for SET clause)
      metaFields->Array.forEach(field => {
        let value =
          data->(Utils.magic: metaFields => dict<unknown>)->Dict.getUnsafe((field :> string))
        params->Array.push(value)->ignore
      })

      promises->Array.push(sql->Postgres.preparedUnsafe(query, params->Obj.magic))->ignore
    })

    Promise.all(promises)
  }

  type progressedChain = {
    chainId: int,
    progressBlockNumber: int,
    sourceBlockNumber: int,
    totalEventsProcessed: float,
  }

  let setProgressedChains = (sql, ~pgSchema, ~progressedChains: array<progressedChain>) => {
    let query = makeProgressFieldsUpdateQuery(~pgSchema)

    let promises = []

    progressedChains->Array.forEach(data => {
      let params = []

      params->Array.push(data.chainId->(Utils.magic: int => unknown))->ignore

      progressFields->Array.forEach(field => {
        params
        ->Array.push(
          switch field {
          | #progress_block => data.progressBlockNumber->(Utils.magic: int => unknown)
          | #events_processed => data.totalEventsProcessed->(Utils.magic: float => unknown)
          | #source_block => data.sourceBlockNumber->(Utils.magic: int => unknown)
          },
        )
        ->ignore
      })

      promises->Array.push(sql->Postgres.preparedUnsafe(query, params->Obj.magic))->ignore
    })

    Promise.all(promises)->Utils.Promise.ignoreValue
  }
}

module EnvioInfo = {
  // Singleton table — written by `initialize` inside the schema-setup
  // transaction, read on resume for the config compat check. The `id`
  // column has a fixed default of 1 plus a primary key, so the table can
  // hold at most one row; `write` upserts on conflict.
  //
  // `config` is TEXT (not JSONB) so the round-trip is byte-stable: jsonb
  // re-serializes numbers/escapes which made the diff produce false
  // positives on harmless format differences.
  let table = mkTable(
    "envio_info",
    ~fields=[
      mkField("id", Int32, ~fieldSchema=S.int, ~isPrimaryKey, ~default="1"),
      mkField("config", String, ~fieldSchema=S.string),
    ],
  )

  // Postgres SQLSTATE for "undefined_table" — what we get when the schema
  // was initialized by an older envio that didn't have `envio_info`.
  let undefinedTableSqlState = "42P01"

  @get external getCode: JsExn.t => option<string> = "code"

  let read = async (sql, ~pgSchema): option<JSON.t> => {
    let rows: array<{
      "config": string,
    }> = try await sql->Postgres.unsafe(
      `SELECT "config" FROM "${pgSchema}"."${table.tableName}" LIMIT 1;`,
    ) catch {
    | exn =>
      switch exn->JsExn.anyToExnInternal {
      | JsExn(e) if e->getCode === Some(undefinedTableSqlState) => []
      | _ => throw(exn)
      }
    }
    rows->Array.get(0)->Option.map(row => row["config"]->JSON.parseOrThrow)
  }

  // Upsert keyed on the fixed id so the table stays a singleton even if
  // `initialize` runs against a non-empty schema (shouldn't happen, but
  // protects against a partially-applied prior run).
  let write = (sql, ~pgSchema, ~envioInfo: JSON.t) => {
    sql
    ->Postgres.preparedUnsafe(
      `INSERT INTO "${pgSchema}"."${table.tableName}" ("id", "config") VALUES (1, $1) ON CONFLICT ("id") DO UPDATE SET "config" = EXCLUDED."config";`,
      [envioInfo->JSON.stringify]->(Utils.magic: array<string> => unknown),
    )
    ->Utils.Promise.ignoreValue
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
    chainId: int,
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
    chainId: s.field("chain_id", S.int),
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

  let initialCheckpointId = 0n

  let table = mkTable(
    "envio_checkpoints",
    ~fields=[
      mkField((#id: field :> string), UInt64, ~fieldSchema=S.bigint, ~isPrimaryKey),
      mkField((#chain_id: field :> string), Int32, ~fieldSchema=S.int),
      mkField((#block_number: field :> string), Int32, ~fieldSchema=S.int),
      mkField((#block_hash: field :> string), String, ~fieldSchema=S.null(S.string), ~isNullable),
      mkField((#events_processed: field :> string), Int32, ~fieldSchema=S.int),
    ],
  )

  let makeGetReorgCheckpointsQuery = (~pgSchema): string => {
    // Use CTE to pre-filter chains and compute safe_block once per chain
    // This is faster because:
    // 1. Chains table is small, so filtering it first is cheap
    // 2. safe_block is computed once per chain, not per checkpoint
    // 3. Query planner can materialize the small CTE result before joining
    `WITH reorg_chains AS (
  SELECT 
    "${(#id: Chains.field :> string)}" as id,
    "${(#source_block: Chains.field :> string)}" - "${(#max_reorg_depth: Chains.field :> string)}" AS safe_block
  FROM "${pgSchema}"."${Chains.table.tableName}"
  WHERE "${(#max_reorg_depth: Chains.field :> string)}" > 0
    AND "${(#progress_block: Chains.field :> string)}" > "${(#source_block: Chains.field :> string)}" - "${(#max_reorg_depth: Chains.field :> string)}"
)
SELECT 
  cp."${(#id: field :> string)}", 
  cp."${(#chain_id: field :> string)}", 
  cp."${(#block_number: field :> string)}", 
  cp."${(#block_hash: field :> string)}"
FROM "${pgSchema}"."${table.tableName}" cp
INNER JOIN reorg_chains rc 
  ON cp."${(#chain_id: field :> string)}" = rc.id
WHERE cp."${(#block_hash: field :> string)}" IS NOT NULL
  AND cp."${(#block_number: field :> string)}" >= rc.safe_block;` // Include safe_block checkpoint to use it for safe checkpoint tracking
  }

  let makeCommitedCheckpointIdQuery = (~pgSchema) => {
    `SELECT COALESCE(MAX(${(#id: field :> string)}), ${initialCheckpointId->BigInt.toString}) AS id FROM "${pgSchema}"."${table.tableName}";`
  }

  let makeInsertCheckpointQuery = (~pgSchema) => {
    `INSERT INTO "${pgSchema}"."${table.tableName}" ("${(#id: field :> string)}", "${(#chain_id: field :> string)}", "${(#block_number: field :> string)}", "${(#block_hash: field :> string)}", "${(#events_processed: field :> string)}")
SELECT * FROM unnest($1::${(BigInt: Postgres.columnType :> string)}[],$2::${(Integer: Postgres.columnType :> string)}[],$3::${(Integer: Postgres.columnType :> string)}[],$4::${(Text: Postgres.columnType :> string)}[],$5::${(Integer: Postgres.columnType :> string)}[]);`
  }

  let insert = (
    sql,
    ~pgSchema,
    ~checkpointIds,
    ~checkpointChainIds,
    ~checkpointBlockNumbers,
    ~checkpointBlockHashes,
    ~checkpointEventsProcessed,
  ) => {
    let query = makeInsertCheckpointQuery(~pgSchema)

    // Convert bigint arrays to string arrays for postgres driver compatibility
    let checkpointIdStrings = checkpointIds->Utils.BigInt.arrayToStringArray
    sql
    ->Postgres.preparedUnsafe(
      query,
      (
        checkpointIdStrings,
        checkpointChainIds,
        checkpointBlockNumbers,
        checkpointBlockHashes,
        checkpointEventsProcessed,
      )->(
        Utils.magic: (
          (array<string>, array<int>, array<int>, array<Null.t<string>>, array<int>)
        ) => unknown
      ),
    )
    ->Utils.Promise.ignoreValue
  }

  let rollback = (sql, ~pgSchema, ~rollbackTargetCheckpointId: Internal.checkpointId) => {
    sql
    ->Postgres.preparedUnsafe(
      `DELETE FROM "${pgSchema}"."${table.tableName}" WHERE "${(#id: field :> string)}" > $1;`,
      [rollbackTargetCheckpointId->BigInt.toString]->(Utils.magic: array<string> => unknown),
    )
    ->Utils.Promise.ignoreValue
  }

  let makePruneStaleCheckpointsQuery = (~pgSchema) => {
    `DELETE FROM "${pgSchema}"."${table.tableName}" WHERE "${(#id: field :> string)}" < $1;`
  }

  let pruneStaleCheckpoints = (sql, ~pgSchema, ~safeCheckpointId: bigint) => {
    sql
    ->Postgres.preparedUnsafe(
      makePruneStaleCheckpointsQuery(~pgSchema),
      [safeCheckpointId->BigInt.toString]->Obj.magic,
    )
    ->Utils.Promise.ignoreValue
  }

  let makeGetRollbackTargetCheckpointQuery = (~pgSchema) => {
    `SELECT "${(#id: field :> string)}" FROM "${pgSchema}"."${table.tableName}"
WHERE 
  "${(#chain_id: field :> string)}" = $1 AND
  "${(#block_number: field :> string)}" <= $2
ORDER BY "${(#id: field :> string)}" DESC
LIMIT 1;`
  }

  let getRollbackTargetCheckpoint = (
    sql,
    ~pgSchema,
    ~reorgChainId: int,
    ~lastKnownValidBlockNumber: int,
  ) => {
    let rawResult: promise<array<{"id": string}>> =
      sql
      ->Postgres.preparedUnsafe(
        makeGetRollbackTargetCheckpointQuery(~pgSchema),
        (reorgChainId, lastKnownValidBlockNumber)->Obj.magic,
      )
      ->(Utils.magic: promise<unknown> => promise<array<{"id": string}>>)
    rawResult->Promise.thenResolve(rows => {
      rows->Array.get(0)->Option.map(row => row["id"]->BigInt.fromStringOrThrow)
    })
  }

  let makeGetRollbackProgressDiffQuery = (~pgSchema) => {
    `SELECT 
  "${(#chain_id: field :> string)}",
  SUM("${(#events_processed: field :> string)}") as events_processed_diff,
  MIN("${(#block_number: field :> string)}") - 1 as new_progress_block_number
FROM "${pgSchema}"."${table.tableName}"
WHERE "${(#id: field :> string)}" > $1
GROUP BY "${(#chain_id: field :> string)}";`
  }

  let getRollbackProgressDiff = (
    sql,
    ~pgSchema,
    ~rollbackTargetCheckpointId: Internal.checkpointId,
  ) => {
    sql
    ->Postgres.preparedUnsafe(
      makeGetRollbackProgressDiffQuery(~pgSchema),
      [rollbackTargetCheckpointId->BigInt.toString]->Obj.magic,
    )
    ->(
      Utils.magic: promise<unknown> => promise<
        array<{
          "chain_id": int,
          "events_processed_diff": string,
          "new_progress_block_number": int,
        }>,
      >
    )
  }
}

module RawEvents = {
  type t = Internal.rawEvent

  let schema = S.schema((s): t => {
    chain_id: s.matches(S.int),
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
      mkField("chain_id", Int32, ~fieldSchema=S.int),
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

// View names for Hasura integration
module Views = {
  let metaViewName = "_meta"
  let chainMetadataViewName = "chain_metadata"

  let makeMetaViewQuery = (~pgSchema) => {
    `CREATE VIEW "${pgSchema}"."${metaViewName}" AS 
SELECT 
  "${(#id: Chains.field :> string)}" AS "chainId",
  "${(#start_block: Chains.field :> string)}" AS "startBlock", 
  "${(#end_block: Chains.field :> string)}" AS "endBlock",
  "${(#progress_block: Chains.field :> string)}" AS "progressBlock",
  "${(#buffer_block: Chains.field :> string)}" AS "bufferBlock",
  "${(#first_event_block: Chains.field :> string)}" AS "firstEventBlock",
  "${(#events_processed: Chains.field :> string)}"::float4 AS "eventsProcessed",
  "${(#source_block: Chains.field :> string)}" AS "sourceBlock",
  "${(#ready_at: Chains.field :> string)}" AS "readyAt",
  ("${(#ready_at: Chains.field :> string)}" IS NOT NULL) AS "isReady"
FROM "${pgSchema}"."${Chains.table.tableName}"
ORDER BY "${(#id: Chains.field :> string)}";`
  }

  let makeChainMetadataViewQuery = (~pgSchema) => {
    `CREATE VIEW "${pgSchema}"."${chainMetadataViewName}" AS 
SELECT 
  "${(#source_block: Chains.field :> string)}" AS "block_height",
  "${(#id: Chains.field :> string)}" AS "chain_id",
  "${(#end_block: Chains.field :> string)}" AS "end_block", 
  "${(#first_event_block: Chains.field :> string)}" AS "first_event_block_number",
  "${(#_is_hyper_sync: Chains.field :> string)}" AS "is_hyper_sync",
  "${(#buffer_block: Chains.field :> string)}" AS "latest_fetched_block_number",
  "${(#progress_block: Chains.field :> string)}" AS "latest_processed_block",
  0 AS "num_batches_fetched",
  "${(#events_processed: Chains.field :> string)}"::float4 AS "num_events_processed",
  "${(#start_block: Chains.field :> string)}" AS "start_block",
  "${(#ready_at: Chains.field :> string)}" AS "timestamp_caught_up_to_head_or_endblock"
FROM "${pgSchema}"."${Chains.table.tableName}";`
  }
}
