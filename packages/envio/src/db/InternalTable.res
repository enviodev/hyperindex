open Table

//shorthand for punning
let isPrimaryKey = true
let isNullable = true
let isIndex = true

// Postgres SQLSTATE for "undefined_table" — what a read gets when the schema was
// initialized by an older envio that didn't have the table.
let undefinedTableSqlState = "42P01"

@get external getSqlStateCode: JsExn.t => option<string> = "code"

let isUndefinedTable = exn =>
  switch exn->JsExn.anyToExnInternal {
  | JsExn(e) => e->getSqlStateCode === Some(undefinedTableSqlState)
  | _ => false
  }

// The array type an unnest binds a chain-id column to. Resolved from the
// config's mode, so every internal query casts the parameter the same way the
// column was created.
let chainIdArrayType = (~pgSchema, ~chainIdMode: ChainId.mode) =>
  Table.getPgFieldType(
    ~fieldType=ChainId,
    ~pgSchema,
    ~isArray=true,
    ~isNumericArrayAsText=false,
    ~isNullable=false,
    ~chainIdMode,
  )

// The canonical contract ids. Written once at initialize from the config's
// contract names in byte order, so an id names the same contract on every
// chain and across restarts; read back on resume, where the stored mapping is
// what every address row means.
module EnvioContracts = {
  let table = mkTable(
    "envio_contracts",
    ~fields=[
      mkField("id", SmallInt, ~fieldSchema=S.int, ~isPrimaryKey),
      mkField("name", String, ~fieldSchema=S.string),
    ],
  )

  let makeInsertQuery = (~pgSchema) =>
    `INSERT INTO "${pgSchema}"."${table.tableName}" ("id", "name")
SELECT * FROM unnest($1::${(SmallInt: Postgres.columnType :> string)}[],$2::${(Text: Postgres.columnType :> string)}[]);`

  // `contractNames` is the canonical list: a name's position is its id.
  let insert = (sql, ~pgSchema, ~contractNames: array<string>) =>
    sql
    ->Postgres.preparedUnsafe(
      makeInsertQuery(~pgSchema),
      (contractNames->Array.mapWithIndex((_, idx) => idx), contractNames)->(
        Utils.magic: ((array<int>, array<string>)) => unknown
      ),
    )
    ->Utils.Promise.ignoreValue

  // Ordered by id, so the result is the canonical list itself. None when the
  // schema has no such table: it was written by an envio that predates the
  // contract mapping, and every address row in it is shaped differently — so a
  // resume has to stop at the compat check rather than at a missing column.
  let read = async (sql, ~pgSchema): option<array<string>> =>
    try {
      let rows: array<{
        "name": string,
      }> = await sql->Postgres.unsafe(
        `SELECT "name" FROM "${pgSchema}"."${table.tableName}" ORDER BY "id";`,
      )
      Some(rows->Array.map(row => row["name"]))
    } catch {
    | exn => isUndefinedTable(exn) ? None : throw(exn)
    }
}

module EnvioAddresses = {
  let name = "envio_addresses"

  let table = mkTable(
    name,
    ~fields=[
      mkField("chain_id", ChainId, ~fieldSchema=ChainId.schema, ~isPrimaryKey),
      // The field schemas are unused: this table is read and written by the
      // hand-written queries below, never through the generic row encoding.
      mkField("address", Bytea, ~fieldSchema=S.string, ~isPrimaryKey),
      mkField("contract_id", SmallInt, ~fieldSchema=S.int, ~isPrimaryKey),
      mkField("registration_block", Int32, ~fieldSchema=S.int),
    ],
  )

  let makeInsertQuery = (~pgSchema, ~chainIdMode: ChainId.mode=Int32) => {
    let chainIdArrayType = chainIdArrayType(~pgSchema, ~chainIdMode)
    `INSERT INTO "${pgSchema}"."${table.tableName}" ("chain_id", "address", "contract_id", "registration_block")
SELECT * FROM unnest($1::${chainIdArrayType},$2::${(Bytea: Postgres.columnType :> string)}[],$3::${(SmallInt: Postgres.columnType :> string)}[],$4::${(Integer: Postgres.columnType :> string)}[])
ON CONFLICT ("chain_id", "address", "contract_id") DO NOTHING;`
  }

  let insert = (
    sql,
    ~pgSchema,
    ~rows: array<AddressRows.row>,
    ~chainIdMode: ChainId.mode=Int32,
  ) => {
    let chainIds = []
    let addresses = []
    let contractIds = []
    let registrationBlocks = []
    rows->Array.forEach(row => {
      chainIds->Array.push(row.chainId)->ignore
      addresses->Array.push(row.address)->ignore
      contractIds->Array.push(row.contractId)->ignore
      registrationBlocks->Array.push(row.registrationBlock)->ignore
    })
    sql
    ->Postgres.preparedUnsafe(
      makeInsertQuery(~pgSchema, ~chainIdMode),
      (
        chainIds,
        sql->Postgres.typed(addresses, Postgres.byteaArrayOid),
        contractIds,
        registrationBlocks,
      )->(Utils.magic: ((array<ChainId.t>, unknown, array<int>, array<int>)) => unknown),
    )
    ->Utils.Promise.ignoreValue
  }

  let makeDeleteQuery = (~pgSchema, ~chainIdMode: ChainId.mode=Int32) => {
    let chainIdArrayType = chainIdArrayType(~pgSchema, ~chainIdMode)
    `DELETE FROM "${pgSchema}"."${table.tableName}"
USING unnest($1::${chainIdArrayType},$2::${(Bytea: Postgres.columnType :> string)}[],$3::${(SmallInt: Postgres.columnType :> string)}[]) AS dead(chain_id, address, contract_id)
WHERE "${table.tableName}"."chain_id" = dead.chain_id
  AND "${table.tableName}"."address" = dead.address
  AND "${table.tableName}"."contract_id" = dead.contract_id;`
  }

  let delete = (
    sql,
    ~pgSchema,
    ~keys: array<AddressRows.key>,
    ~chainIdMode: ChainId.mode=Int32,
  ) => {
    let chainIds = []
    let addresses = []
    let contractIds = []
    keys->Array.forEach(key => {
      chainIds->Array.push(key.chainId)->ignore
      addresses->Array.push(key.address)->ignore
      contractIds->Array.push(key.contractId)->ignore
    })
    sql
    ->Postgres.preparedUnsafe(
      makeDeleteQuery(~pgSchema, ~chainIdMode),
      (chainIds, sql->Postgres.typed(addresses, Postgres.byteaArrayOid), contractIds)->(
        Utils.magic: ((array<ChainId.t>, unknown, array<int>)) => unknown
      ),
    )
    ->Utils.Promise.ignoreValue
  }

  let makeGetRowsQuery = (~pgSchema) =>
    `SELECT "chain_id" as "chainId",
"address" as "address",
"contract_id" as "contractId",
"registration_block" as "registrationBlock"
FROM "${pgSchema}"."${table.tableName}";`
}

module Chains = {
  type progressFields = [
    | #progress_block
    | #events_processed
    | #source_block
  ]

  type field = [
    | progressFields
    | #id
    | #ecosystem
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
    #ecosystem,
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
    @as("id") id: ChainId.t,
    @as("ecosystem") ecosystem: string,
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
      mkField((#id: field :> string), ChainId, ~fieldSchema=ChainId.schema, ~isPrimaryKey),
      // Which ecosystem the chain belongs to (evm / fuel / svm). Chain ids are
      // only unique within an ecosystem (HOS-1880: Svm ids are Envio-assigned),
      // so consumers should treat (ecosystem, id) as the chain's identity.
      mkField((#ecosystem: field :> string), String, ~fieldSchema=S.string),
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
      ecosystem: (chainConfig.ecosystem: Ecosystem.name :> string),
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
          | #string => `'${value->(Utils.magic: option<unknown> => string)}'`
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

  // Written only once every schema-defined index is verified, so a chain is
  // never reported ready without the indexes the schema promises. One row at a
  // time, like `setMeta`: the id column is INTEGER or BIGINT depending on the
  // configured `ChainId.mode`, and a bare `= $2` needs no cast either way.
  //
  // `IS NULL` so a chain keeps the timestamp it first caught up at, matching the
  // sticky in-memory `ChainState.markReady`. Without it a partial recovery (eg a
  // chain added to an already-synced indexer) would restamp the ready chains in
  // the database while their in-memory copies kept the old value — and the next
  // chain-metadata write would push the stale value back over the committed one.
  let makeSetReadyAtQuery = (~pgSchema) =>
    `UPDATE "${pgSchema}"."${table.tableName}"
SET "${(#ready_at: field :> string)}" = $1
WHERE "${(#id: field :> string)}" = $2
  AND "${(#ready_at: field :> string)}" IS NULL;`

  type rawInitialState = {
    id: ChainId.t,
    startBlock: int,
    endBlock: Null.t<int>,
    maxReorgDepth: int,
    firstEventBlockNumber: Null.t<int>,
    timestampCaughtUpToHeadOrEndblock: Null.t<Date.t>,
    numEventsProcessed: float,
    progressBlockNumber: int,
    addressRows: AddressRows.seedRows,
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

  // Addresses are read as plain rows rather than aggregated per chain with
  // json_agg: a single chain's aggregate can exceed V8's max string length
  // (postgres.js decodes the column with Buffer.toString and throws
  // ERR_STRING_TOO_LONG). Grouping happens in JS instead — see getInitialState.
  let getInitialState = async (sql, ~pgSchema) => {
    let (rawInitialStates, rawAddressRows) = await Promise.all2((
      sql
      ->Postgres.unsafe(makeGetInitialStateQuery(~pgSchema))
      ->(Utils.magic: promise<array<unknown>> => promise<array<rawInitialState>>),
      sql
      ->Postgres.unsafe(EnvioAddresses.makeGetRowsQuery(~pgSchema))
      ->(Utils.magic: promise<array<unknown>> => promise<array<AddressRows.row>>),
    ))

    let addressRowsByChainId = rawAddressRows->AddressRows.group

    rawInitialStates->Array.map(rawInitialState => {
      let id = rawInitialState.id->ChainId.normalizeOrThrow
      {
        ...rawInitialState,
        id,
        addressRows: addressRowsByChainId
        ->Utils.Dict.dangerouslyGetNonOption(id->ChainId.toString)
        ->Option.getOr(AddressRows.emptySeedRows()),
      }
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
    chainId: ChainId.t,
    progressBlockNumber: int,
    sourceBlockNumber: int,
    totalEventsProcessed: float,
  }

  let setProgressedChains = (sql, ~pgSchema, ~progressedChains: array<progressedChain>) => {
    let query = makeProgressFieldsUpdateQuery(~pgSchema)

    let promises = []

    progressedChains->Array.forEach(data => {
      let params = []

      params->Array.push(data.chainId->(Utils.magic: ChainId.t => unknown))->ignore

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

  let read = async (sql, ~pgSchema): option<JSON.t> => {
    let rows: array<{
      "config": string,
    }> = try await sql->Postgres.unsafe(
      `SELECT "config" FROM "${pgSchema}"."${table.tableName}" LIMIT 1;`,
    ) catch {
    | exn => isUndefinedTable(exn) ? [] : throw(exn)
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

  let initialCheckpointId = 0n

  // One definition per column, carrying what each storage needs: the field
  // itself, the type ClickHouse gives it where that differs from Postgres, and
  // where a batch keeps the column's values.
  type column = {
    field: fieldOrDerived,
    clickHouseFieldType: fieldType,
    valuesOf: Batch.t => array<unknown>,
  }

  let columns: array<column> = [
    {
      field: mkField((#id: field :> string), UInt64, ~fieldSchema=S.bigint, ~isPrimaryKey),
      clickHouseFieldType: UInt64,
      valuesOf: batch => batch.checkpointIds->(Utils.magic: array<bigint> => array<unknown>),
    },
    {
      field: mkField((#chain_id: field :> string), ChainId, ~fieldSchema=ChainId.schema),
      clickHouseFieldType: ChainId,
      valuesOf: batch =>
        batch.checkpointChainIds->(Utils.magic: array<ChainId.t> => array<unknown>),
    },
    {
      field: mkField((#block_number: field :> string), Int32, ~fieldSchema=S.int),
      clickHouseFieldType: Int32,
      valuesOf: batch => batch.checkpointBlockNumbers->(Utils.magic: array<int> => array<unknown>),
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
    },
    {
      field: mkField((#events_processed: field :> string), Int32, ~fieldSchema=S.int),
      // A count of every event a chain has processed outgrows an Int32 where
      // Postgres keeps one, and ClickHouse has the id's width to spare.
      clickHouseFieldType: UInt64,
      valuesOf: batch =>
        batch.checkpointEventsProcessed->(Utils.magic: array<int> => array<unknown>),
    },
  ]

  let table = mkTable("envio_checkpoints", ~fields=columns->Array.map(({field}) => field))

  let makeGetReorgCheckpointsQuery = (~pgSchema): string => {
    // The safe_block checkpoint itself is included, so it can be used for safe
    // checkpoint tracking.
    //
    // Ordered by id, which within a chain is block order: both consumers of
    // these rows — the safe-checkpoint scan and the block-store seed — read them
    // as ascending. Physical row order can't stand in for that, since a rollback
    // frees space that later checkpoints are written back into.
    //
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
  AND cp."${(#block_number: field :> string)}" >= rc.safe_block
ORDER BY cp."${(#id: field :> string)}";`
  }

  let makeCommitedCheckpointIdQuery = (~pgSchema) => {
    `SELECT COALESCE(MAX(${(#id: field :> string)}), ${initialCheckpointId->BigInt.toString}) AS id FROM "${pgSchema}"."${table.tableName}";`
  }

  let makeInsertCheckpointQuery = (~pgSchema, ~chainIdMode: ChainId.mode=Int32) => {
    let chainIdArrayType = chainIdArrayType(~pgSchema, ~chainIdMode)
    `INSERT INTO "${pgSchema}"."${table.tableName}" ("${(#id: field :> string)}", "${(#chain_id: field :> string)}", "${(#block_number: field :> string)}", "${(#block_hash: field :> string)}", "${(#events_processed: field :> string)}")
SELECT * FROM unnest($1::${(BigInt: Postgres.columnType :> string)}[],$2::${chainIdArrayType},$3::${(Integer: Postgres.columnType :> string)}[],$4::${(Text: Postgres.columnType :> string)}[],$5::${(Integer: Postgres.columnType :> string)}[]);`
  }

  let insert = (
    sql,
    ~pgSchema,
    ~checkpointIds,
    ~checkpointChainIds,
    ~checkpointBlockNumbers,
    ~checkpointBlockHashes,
    ~checkpointEventsProcessed,
    ~chainIdMode: ChainId.mode=Int32,
  ) => {
    let query = makeInsertCheckpointQuery(~pgSchema, ~chainIdMode)

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
          (array<string>, array<ChainId.t>, array<int>, array<Null.t<string>>, array<int>)
        ) => unknown
      ),
    )
    ->Utils.Promise.ignoreValue
  }

  // Optional to match the entity tables', where a cross-chain entity has none.
  let chainIdColumn = Some((#chain_id: field :> string))

  let rollback = (
    sql,
    ~pgSchema,
    ~scope: RollbackScope.t,
    ~rollbackTargetCheckpointId: Internal.checkpointId,
  ) => {
    sql
    ->Postgres.preparedUnsafe(
      `DELETE FROM "${pgSchema}"."${table.tableName}" WHERE "${(#id: field :> string)}" > $1${scope->RollbackScope.predicate(
          ~chainIdColumn,
        )};`,
      scope->RollbackScope.params(~targetCheckpointId=rollbackTargetCheckpointId),
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
    ~reorgChainId: ChainId.t,
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

  let makeGetRollbackProgressDiffQuery = (~pgSchema, ~scope: RollbackScope.t) => {
    `SELECT 
  "${(#chain_id: field :> string)}"::float8 as "${(#chain_id: field :> string)}",
  SUM("${(#events_processed: field :> string)}") as events_processed_diff,
  MIN("${(#block_number: field :> string)}") - 1 as new_progress_block_number
FROM "${pgSchema}"."${table.tableName}"
WHERE "${(#id: field :> string)}" > $1${scope->RollbackScope.predicate(~chainIdColumn)}
GROUP BY "${(#chain_id: field :> string)}";`
  }

  let getRollbackProgressDiff = (
    sql,
    ~pgSchema,
    ~scope: RollbackScope.t,
    ~rollbackTargetCheckpointId: Internal.checkpointId,
  ) => {
    sql
    ->Postgres.preparedUnsafe(
      makeGetRollbackProgressDiffQuery(~pgSchema, ~scope),
      scope->RollbackScope.params(~targetCheckpointId=rollbackTargetCheckpointId),
    )
    ->(
      Utils.magic: promise<unknown> => promise<
        array<{
          "chain_id": ChainId.t,
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

// View names for Hasura integration
module Views = {
  let metaViewName = "_meta"
  let chainMetadataViewName = "chain_metadata"

  let makeMetaViewQuery = (~pgSchema) => {
    `CREATE VIEW "${pgSchema}"."${metaViewName}" AS 
SELECT 
  "${(#id: Chains.field :> string)}" AS "chainId",
  "${(#ecosystem: Chains.field :> string)}" AS "ecosystem",
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
  "${(#ecosystem: Chains.field :> string)}" AS "ecosystem",
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
