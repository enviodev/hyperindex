open Table

//shorthand for punning
let isPrimaryKey = true
let isNullable = true
let isIndex = true

module DynamicContractRegistry = {
  let name = "dynamic_contract_registry"

  let makeId = (~chainId, ~contractAddress) => {
    chainId->Belt.Int.toString ++ "-" ++ contractAddress->Address.toString
  }

  // @genType Used for Test DB
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
    @as("contract_name") contractName: string,
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
    contractName: s.matches(S.string),
  })

  let rowsSchema = S.array(schema)

  let table = mkTable(
    name,
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
      mkField("contract_name", Text, ~fieldSchema=S.string),
    ],
  )

  let entityHistory = table->EntityHistory.fromTable(~schema)

  external castToInternal: t => Internal.entity = "%identity"

  let config = {
    name,
    schema,
    rowsSchema,
    table,
    entityHistory,
  }->Internal.fromGenericEntityConfig
}

module Chains = {
  type progressFields = [
    | #progress_block
    | #events_processed
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
    | #_num_batches_fetched
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
    #_num_batches_fetched,
  ]

  type metaFields = {
    @as("first_event_block") firstEventBlockNumber: Js.null<int>,
    @as("buffer_block") latestFetchedBlockNumber: int,
    @as("source_block") blockHeight: int,
    @as("ready_at")
    timestampCaughtUpToHeadOrEndblock: Js.null<Js.Date.t>,
    @as("_is_hyper_sync") isHyperSync: bool,
    @as("_num_batches_fetched") numBatchesFetched: int,
  }

  type t = {
    @as("id") id: int,
    @as("start_block") startBlock: int,
    @as("end_block") endBlock: Js.null<int>,
    @as("max_reorg_depth") maxReorgDepth: int,
    @as("progress_block") progressBlockNumber: int,
    @as("events_processed") numEventsProcessed: int,
    ...metaFields,
  }

  let table = mkTable(
    "envio_chains",
    ~fields=[
      mkField((#id: field :> string), Integer, ~fieldSchema=S.int, ~isPrimaryKey),
      // Values populated from config
      mkField((#start_block: field :> string), Integer, ~fieldSchema=S.int),
      mkField((#end_block: field :> string), Integer, ~fieldSchema=S.null(S.int), ~isNullable),
      mkField((#max_reorg_depth: field :> string), Integer, ~fieldSchema=S.int),
      // Block number of the latest block that was fetched from the source
      mkField((#buffer_block: field :> string), Integer, ~fieldSchema=S.int),
      // Block number of the currently active source
      mkField((#source_block: field :> string), Integer, ~fieldSchema=S.int),
      // Block number of the first event that was processed for this chain
      mkField(
        (#first_event_block: field :> string),
        Integer,
        ~fieldSchema=S.null(S.int),
        ~isNullable,
      ),
      // Used to show how much time historical sync has taken, so we need a timezone here (TUI and Hosted Service)
      // null during historical sync, set to current time when sync is complete
      mkField(
        (#ready_at: field :> string),
        TimestampWithNullTimezone,
        ~fieldSchema=S.null(Utils.Schema.dbDate),
        ~isNullable,
      ),
      mkField((#events_processed: field :> string), Integer, ~fieldSchema=S.int),
      // TODO: In the future it should reference a table with sources
      mkField((#_is_hyper_sync: field :> string), Boolean, ~fieldSchema=S.bool),
      // Fully processed block number
      mkField((#progress_block: field :> string), Integer, ~fieldSchema=S.int),
      // TODO: Should deprecate after changing the ETA calculation logic
      mkField((#_num_batches_fetched: field :> string), Integer, ~fieldSchema=S.int),
    ],
  )

  let initialFromConfig = (chainConfig: InternalConfig.chain) => {
    {
      id: chainConfig.id,
      startBlock: chainConfig.startBlock,
      endBlock: chainConfig.endBlock->Js.Null.fromOption,
      maxReorgDepth: chainConfig.maxReorgDepth,
      blockHeight: 0,
      firstEventBlockNumber: Js.Null.empty,
      latestFetchedBlockNumber: -1,
      timestampCaughtUpToHeadOrEndblock: Js.Null.empty,
      progressBlockNumber: -1,
      isHyperSync: false,
      numEventsProcessed: 0,
      numBatchesFetched: 0,
    }
  }

  let makeInitialValuesQuery = (~pgSchema, ~chainConfigs: array<InternalConfig.chain>) => {
    if chainConfigs->Array.length === 0 {
      None
    } else {
      // Create column names list
      let columnNames = fields->Belt.Array.map(field => `"${(field :> string)}"`)

      // Create VALUES rows for each chain config
      let valuesRows = chainConfigs->Belt.Array.map(chainConfig => {
        let initialValues = initialFromConfig(chainConfig)
        let values = fields->Belt.Array.map((field: field) => {
          let value =
            initialValues->(Utils.magic: t => dict<unknown>)->Js.Dict.get((field :> string))
          switch Js.typeof(value) {
          | "object" => "NULL"
          | "number" => value->Utils.magic->Belt.Int.toString
          | "boolean" => value->Utils.magic ? "true" : "false"
          | _ => Js.Exn.raiseError("Invalid envio_chains value type")
          }
        })

        `(${values->Js.Array2.joinWith(", ")})`
      })

      Some(
        `INSERT INTO "${pgSchema}"."${table.tableName}" (${columnNames->Js.Array2.joinWith(", ")})
VALUES ${valuesRows->Js.Array2.joinWith(",\n       ")};`,
      )
    }
  }

  // Fields that can be updated outside of the batch transaction
  let metaFields: array<field> = [
    #source_block,
    #buffer_block,
    #first_event_block,
    #ready_at,
    #_is_hyper_sync,
    #_num_batches_fetched,
  ]

  let makeMetaFieldsUpdateQuery = (~pgSchema) => {
    // Generate SET clauses with parameter placeholders
    let setClauses = Belt.Array.mapWithIndex(metaFields, (index, field) => {
      let fieldName = (field :> string)
      let paramIndex = index + 2 // +2 because $1 is for id in WHERE clause
      `"${fieldName}" = $${Belt.Int.toString(paramIndex)}`
    })

    `UPDATE "${pgSchema}"."${table.tableName}"
SET ${setClauses->Js.Array2.joinWith(",\n    ")}
WHERE "${(#id: field :> string)}" = $1;`
  }

  type rawInitialState = {
    id: int,
    startBlock: int,
    endBlock: Js.Null.t<int>,
    maxReorgDepth: int,
    firstEventBlockNumber: Js.Null.t<int>,
    timestampCaughtUpToHeadOrEndblock: Js.Null.t<Js.Date.t>,
    numEventsProcessed: int,
    progressBlockNumber: int,
    dynamicContracts: array<Internal.indexingContract>,
  }

  // FIXME: Using registering_event_block_number for startBlock
  // seems incorrect, since there might be a custom start block
  // for the contract.
  // TODO: Write a repro test where it might break something and fix
  let makeGetInitialStateQuery = (~pgSchema) => {
    `SELECT "${(#id: field :> string)}" as "id",
"${(#start_block: field :> string)}" as "startBlock",
"${(#end_block: field :> string)}" as "endBlock",
"${(#max_reorg_depth: field :> string)}" as "maxReorgDepth",
"${(#first_event_block: field :> string)}" as "firstEventBlockNumber",
"${(#ready_at: field :> string)}" as "timestampCaughtUpToHeadOrEndblock",
"${(#events_processed: field :> string)}" as "numEventsProcessed",
"${(#progress_block: field :> string)}" as "progressBlockNumber",
(
  SELECT COALESCE(json_agg(json_build_object(
    'address', "contract_address",
    'contractName', "contract_name",
    'startBlock', "registering_event_block_number",
    'registrationBlock', "registering_event_block_number"
  )), '[]'::json)
  FROM "${pgSchema}"."${DynamicContractRegistry.table.tableName}"
  WHERE "chain_id" = chains."${(#id: field :> string)}"
) as "dynamicContracts"
FROM "${pgSchema}"."${table.tableName}" as chains;`
  }

  let getInitialState = (sql, ~pgSchema) => {
    sql
    ->Postgres.unsafe(makeGetInitialStateQuery(~pgSchema))
    ->(Utils.magic: promise<array<unknown>> => promise<array<rawInitialState>>)
  }

  let progressFields: array<progressFields> = [#progress_block, #events_processed]

  let makeProgressFieldsUpdateQuery = (~pgSchema) => {
    let setClauses = Belt.Array.mapWithIndex(progressFields, (index, field) => {
      let fieldName = (field :> string)
      let paramIndex = index + 2 // +2 because $1 is for id in WHERE clause
      `"${fieldName}" = $${Belt.Int.toString(paramIndex)}`
    })

    `UPDATE "${pgSchema}"."${table.tableName}"
SET ${setClauses->Js.Array2.joinWith(",\n    ")}
WHERE "id" = $1;`
  }

  let setMeta = (sql, ~pgSchema, ~chainsData: dict<metaFields>) => {
    let query = makeMetaFieldsUpdateQuery(~pgSchema)

    let promises = []

    chainsData->Utils.Dict.forEachWithKey((data, chainId) => {
      let params = []

      // Push id first (for WHERE clause)
      params->Js.Array2.push(chainId->(Utils.magic: string => unknown))->ignore

      // Then push all updateable field values (for SET clause)
      metaFields->Js.Array2.forEach(field => {
        let value =
          data->(Utils.magic: metaFields => dict<unknown>)->Js.Dict.unsafeGet((field :> string))
        params->Js.Array2.push(value)->ignore
      })

      promises->Js.Array2.push(sql->Postgres.preparedUnsafe(query, params->Obj.magic))->ignore
    })

    Promise.all(promises)
  }

  type progressedChain = {
    chainId: int,
    progressBlockNumber: int,
    totalEventsProcessed: int,
  }

  let setProgressedChains = (sql, ~pgSchema, ~progressedChains: array<progressedChain>) => {
    let query = makeProgressFieldsUpdateQuery(~pgSchema)

    let promises = []

    progressedChains->Js.Array2.forEach(data => {
      let params = []

      // Push id first (for WHERE clause)
      params->Js.Array2.push(data.chainId->(Utils.magic: int => unknown))->ignore

      // Then push all updateable field values (for SET clause)
      progressFields->Js.Array2.forEach(field => {
        params
        ->Js.Array2.push(
          switch field {
          | #progress_block => data.progressBlockNumber->(Utils.magic: int => unknown)
          | #events_processed => data.totalEventsProcessed->(Utils.magic: int => unknown)
          },
        )
        ->ignore
      })

      promises->Js.Array2.push(sql->Postgres.preparedUnsafe(query, params->Obj.magic))->ignore
    })

    Promise.all(promises)->Promise.ignoreValue
  }
}

module PersistedState = {
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

module Checkpoints = {
  type field = [
    | #id
    | #chain_id
    | #block_number
    | #block_hash
    | #events_processed
  ]

  type t = {
    id: int,
    @as("chain_id")
    chainId: int,
    @as("block_number")
    blockNumber: int,
    @as("block_hash")
    blockHash: Js.null<string>,
    @as("events_processed")
    eventsProcessed: int,
  }

  let initialCheckpointId = 0

  let table = mkTable(
    "envio_checkpoints",
    ~fields=[
      mkField((#id: field :> string), Integer, ~fieldSchema=S.int, ~isPrimaryKey),
      mkField((#chain_id: field :> string), Integer, ~fieldSchema=S.int),
      mkField((#block_number: field :> string), Integer, ~fieldSchema=S.int),
      mkField((#block_hash: field :> string), Text, ~fieldSchema=S.null(S.string), ~isNullable),
      mkField((#events_processed: field :> string), Integer, ~fieldSchema=S.int),
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
    `SELECT COALESCE(MAX(${(#id: field :> string)}), ${initialCheckpointId->Belt.Int.toString}) AS id FROM "${pgSchema}"."${table.tableName}";`
  }

  let makeInsertCheckpointQuery = (~pgSchema) => {
    `INSERT INTO "${pgSchema}"."${table.tableName}" ("${(#id: field :> string)}", "${(#chain_id: field :> string)}", "${(#block_number: field :> string)}", "${(#block_hash: field :> string)}", "${(#events_processed: field :> string)}")
SELECT * FROM unnest($1::${(Integer :> string)}[],$2::${(Integer :> string)}[],$3::${(Integer :> string)}[],$4::${(Text :> string)}[],$5::${(Integer :> string)}[]);`
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

    sql
    ->Postgres.preparedUnsafe(
      query,
      (
        checkpointIds,
        checkpointChainIds,
        checkpointBlockNumbers,
        checkpointBlockHashes,
        checkpointEventsProcessed,
      )->(
        Utils.magic: (
          (array<int>, array<int>, array<int>, array<Js.Null.t<string>>, array<int>)
        ) => unknown
      ),
    )
    ->Promise.ignoreValue
  }

  let rollback = (sql, ~pgSchema, ~rollbackTargetCheckpointId: int) => {
    sql
    ->Postgres.preparedUnsafe(
      `DELETE FROM "${pgSchema}"."${table.tableName}" WHERE "${(#id: field :> string)}" > $1;`,
      [rollbackTargetCheckpointId]->Utils.magic,
    )
    ->Promise.ignoreValue
  }

  let makePruneStaleCheckpointsQuery = (~pgSchema) => {
    `DELETE FROM "${pgSchema}"."${table.tableName}" WHERE "${(#id: field :> string)}" < $1;`
  }

  let pruneStaleCheckpoints = (sql, ~pgSchema, ~safeCheckpointId: int) => {
    sql
    ->Postgres.preparedUnsafe(
      makePruneStaleCheckpointsQuery(~pgSchema),
      [safeCheckpointId]->Obj.magic,
    )
    ->Promise.ignoreValue
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
    sql
    ->Postgres.preparedUnsafe(
      makeGetRollbackTargetCheckpointQuery(~pgSchema),
      (reorgChainId, lastKnownValidBlockNumber)->Obj.magic,
    )
    ->(Utils.magic: promise<unknown> => promise<array<{"id": int}>>)
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

  let getRollbackProgressDiff = (sql, ~pgSchema, ~rollbackTargetCheckpointId: int) => {
    sql
    ->Postgres.preparedUnsafe(
      makeGetRollbackProgressDiffQuery(~pgSchema),
      [rollbackTargetCheckpointId]->Obj.magic,
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
  // @genType Used for Test DB and internal tests
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
    "raw_events",
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
      mkField("serial", Serial, ~isNullable, ~isPrimaryKey, ~fieldSchema=S.null(S.int)),
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
       "${(#events_processed: Chains.field :> string)}" AS "eventsProcessed",
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
       "${(#_num_batches_fetched: Chains.field :> string)}" AS "num_batches_fetched",
       "${(#events_processed: Chains.field :> string)}" AS "num_events_processed",
       "${(#start_block: Chains.field :> string)}" AS "start_block",
       "${(#ready_at: Chains.field :> string)}" AS "timestamp_caught_up_to_head_or_endblock"
     FROM "${pgSchema}"."${Chains.table.tableName}";`
  }
}
