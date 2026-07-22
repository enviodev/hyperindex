// ClickHouse client bindings for @clickhouse/client

type client

type clientConfig = {
  url?: string,
  database?: string,
  username?: string,
  password?: string,
}

type execParams = {query: string}

@module("@clickhouse/client")
external createClient: clientConfig => client = "createClient"

@send
external exec: (client, execParams) => promise<unit> = "exec"

@send
external close: client => promise<unit> = "close"

type insertParams<'a> = {
  table: string,
  values: array<'a>,
  format: string,
}

@send
external insert: (client, insertParams<'a>) => promise<unit> = "insert"

type queryParams = {query: string}
type queryResult<'a>

@send
external query: (client, queryParams) => promise<queryResult<'a>> = "query"

// The default `JSON` query format resolves to a `ResponseJSON` wrapper whose
// rows live under `data`, not at the top level.
@send
external json: queryResult<'a> => promise<{"data": array<'a>}> = "json"

let getClickHouseFieldType = (
  ~fieldType: Table.fieldType,
  ~isNullable: bool,
  ~isArray: bool,
): string => {
  let baseType = switch fieldType {
  | Int32 => "Int32"
  | Uint32 => "UInt32"
  | UInt52 => "UInt64"
  | UInt64 => "UInt64"
  | Serial => "Int32"
  | BigSerial => "Int64"
  | BigInt({?precision}) =>
    switch precision {
    | None => "String" // Fallback for unbounded BigInt
    | Some(precision) =>
      if precision > 38 {
        "String"
      } else {
        `Decimal(${precision->Int.toString},0)`
      }
    }
  | BigDecimal({?config}) =>
    switch config {
    | None => "String" // Fallback for unbounded BigDecimal
    | Some((precision, scale)) =>
      if precision > 38 || scale > precision {
        "String"
      } else {
        `Decimal(${precision->Int.toString},${scale->Int.toString})`
      }
    }
  | Boolean => "Bool"
  | Number => "Float64"
  | String => "String"
  | Json => "String"
  | Date => "DateTime64(3, 'UTC')"
  | Enum({config}) => {
      let variantsLength = config.variants->Array.length
      // Theoretically we can store 256 variants in Enum8,
      // but it'd require to explicitly start with a negative index (probably)
      let enumType = variantsLength <= 127 ? "Enum8" : "Enum16"
      let enumValues =
        config.variants
        ->Array.map(variant => {
          let variantStr = variant->(Utils.magic: 'a => string)
          `'${variantStr}'`
        })
        ->Array.joinUnsafe(", ")
      `${enumType}(${enumValues})`
    }
  | Entity(_) => "String"
  }

  let baseType = if isArray {
    `Array(${baseType})`
  } else {
    baseType
  }

  isNullable ? `Nullable(${baseType})` : baseType
}

// Creates an entity schema from table definition, using clickHouseDate for Date fields.
// Serialized keys are the db column names, while the entity values are keyed
// by API field names (they only differ when column renaming is configured).
let makeClickHouseEntitySchema = (table: Table.table): S.t<Internal.entity> => {
  S.object(s => {
    let dict = Dict.make()
    table.fields->Array.forEach(field => {
      switch field {
      | Field(f) => {
          let fieldName = f->Table.getClickHouseDbFieldName
          let fieldSchema = switch f.fieldType {
          | Date => {
              let dateSchema = Utils.Schema.clickHouseDate->S.toUnknown
              if f.isNullable {
                S.null(dateSchema)->S.toUnknown
              } else if f.isArray {
                S.array(dateSchema)->S.toUnknown
              } else {
                dateSchema
              }
            }
          // ClickHouse returns UInt64 values as strings, need to parse to float
          | UInt52 => {
              let uint52Schema =
                S.float
                ->S.preprocess(
                  _ => {
                    parser: unknown => unknown->(Utils.magic: unknown => string)->Float.parseFloat,
                  },
                )
                ->S.toUnknown
              if f.isNullable {
                S.null(uint52Schema)->S.toUnknown
              } else if f.isArray {
                S.array(uint52Schema)->S.toUnknown
              } else {
                uint52Schema
              }
            }
          | _ => f.fieldSchema
          }
          dict->Dict.set(f->Table.getApiFieldName, s.field(fieldName, fieldSchema))
        }
      | DerivedFrom(_) => () // Skip derived fields
      }
    })
    dict->(Utils.magic: dict<unknown> => Internal.entity)
  })
}

let logger = Logging.createChild(~params={"context": "ClickHouse"})

// On transient failure, split values in half and retry each half.
// If only 1 row remains, retry with delay.
// Delay scales from 100ms to 1000ms as retries decrease.
let rec insertWithRetry = async (
  client,
  ~table: string,
  ~values: array<'a>,
  ~format: string,
  ~retries=8,
) => {
  try {
    await client->insert({table, values, format})
  } catch {
  | exn if retries > 0 =>
    let delayMs = Math.Int.min(1000, 100 + 900 * (8 - retries) / 7)
    if Array.length(values) > 1 {
      logger->Logging.childWarn({
        "msg": "ClickHouse insert failed, splitting batch in half and retrying",
        "table": table,
        "batchSize": Array.length(values),
        "retriesLeft": retries,
        "err": exn->Utils.prettifyExn,
      })
      await Utils.delay(delayMs)
      let mid = Array.length(values) / 2
      let first = values->Array.slice(~start=0, ~end=mid)
      let second = values->Array.slice(~start=mid)
      await insertWithRetry(client, ~table, ~values=first, ~format, ~retries=retries - 1)
      await insertWithRetry(client, ~table, ~values=second, ~format, ~retries=retries - 1)
    } else {
      logger->Logging.childWarn({
        "msg": "ClickHouse insert failed, retrying after delay",
        "table": table,
        "retriesLeft": retries,
        "err": exn->Utils.prettifyExn,
      })
      await Utils.delay(delayMs)
      await insertWithRetry(client, ~table, ~values, ~format, ~retries=retries - 1)
    }
  }
}

let setCheckpointsOrThrow = async (client, ~batch: Batch.t, ~database: string) => {
  let checkpointsCount = batch.checkpointIds->Array.length
  if checkpointsCount === 0 {
    ()
  } else {
    // Convert columnar data to row format for JSONCompactEachRow
    let checkpointRows = []
    for idx in 0 to checkpointsCount - 1 {
      checkpointRows
      ->Array.push((
        batch.checkpointIds->Array.getUnsafe(idx)->BigInt.toString,
        batch.checkpointChainIds->Array.getUnsafe(idx),
        batch.checkpointBlockNumbers->Array.getUnsafe(idx),
        batch.checkpointBlockHashes->Array.getUnsafe(idx),
        batch.checkpointEventsProcessed->Array.getUnsafe(idx),
      ))
      ->ignore
    }

    try {
      await insertWithRetry(
        client,
        ~table=`${database}.\`${InternalTable.Checkpoints.table.tableName}\``,
        ~values=checkpointRows,
        ~format="JSONCompactEachRow",
      )
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to insert checkpoints into ClickHouse table "${InternalTable.Checkpoints.table.tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

type setUpdatesCache = {
  tableName: string,
  convertOrThrow: array<Change.t<Internal.entity>> => array<JSON.t>,
}

let setUpdatesOrThrow = async (
  client,
  ~cache: Utils.WeakMap.t<Internal.entityConfig, setUpdatesCache>,
  ~changes: array<Change.t<Internal.entity>>,
  ~entityConfig: Internal.entityConfig,
  ~database: string,
) => {
  if changes->Array.length === 0 {
    ()
  } else {
    let {convertOrThrow, tableName} = switch cache->Utils.WeakMap.get(entityConfig) {
    | Some(cached) => cached
    | None =>
      let cached: setUpdatesCache = {
        tableName: `${database}.\`${EntityHistory.historyTableName(
            ~entityName=entityConfig.name,
            ~entityIndex=entityConfig.index,
          )}\``,
        convertOrThrow: S.compile(
          S.array(
            S.union([
              EntityHistory.makeSetUpdateSchema(makeClickHouseEntitySchema(entityConfig.table)),
              S.object(s => {
                s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
                Change.Delete({
                  entityId: s.field(Table.idFieldName, S.string),
                  checkpointId: s.field(
                    EntityHistory.checkpointIdFieldName,
                    EntityHistory.unsafeCheckpointIdSchema,
                  ),
                })
              }),
            ]),
          ),
          ~input=Value,
          ~output=Json,
          ~typeValidation=false,
          ~mode=Sync,
        )->(
          Utils.magic: (array<Change.t<Internal.entity>> => JSON.t) => array<
            Change.t<Internal.entity>,
          > => array<JSON.t>
        ),
      }

      cache->Utils.WeakMap.set(entityConfig, cached)->ignore
      cached
    }

    try {
      // The entity history table is the source of truth for ClickHouse, so every
      // intermediate change must be persisted, not only the current value.
      let values = changes->convertOrThrow

      await insertWithRetry(client, ~table=tableName, ~values, ~format="JSONEachRow")
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to insert items into ClickHouse table "${tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// A plain database created with ON CLUSTER doesn't turn subsequent DDL into
// cluster-wide statements; ClickHouse keeps no "this database is clustered"
// flag. Without a Replicated database engine, every CREATE must carry its own
// ON CLUSTER to reach all replicas, otherwise it runs only on the connected
// node. With a Replicated database engine the DDL propagates via the database's
// own log, and combining it with ON CLUSTER is rejected/double-applied — so
// table-level DDL must carry the clause only in the plain-database case.
// The '{cluster}' macro resolves to each node's configured cluster name.
let onClusterClause = (~onCluster: bool) => onCluster ? ` ON CLUSTER '{cluster}'` : ""

// Strip both engine arguments `(...)` and a trailing `SETTINGS ...` clause to
// get the bare engine name, e.g. `Replicated('/p','{shard}','{replica}') SETTINGS x=1`
// and `Replicated SETTINGS x=1` both yield `Replicated`.
let databaseEngineName = (engineSpec: string) =>
  engineSpec
  ->String.trim
  ->String.split("(")
  ->Array.getUnsafe(0)
  ->String.split(" ")
  ->Array.getUnsafe(0)
  ->String.trim

// Generate CREATE TABLE query for entity history table
let makeCreateHistoryTableQuery = (
  ~entityConfig: Internal.entityConfig,
  ~database: string,
  ~replicated: bool=false,
  ~onCluster: bool=false,
) => {
  let tableEngine = replicated ? "ReplicatedMergeTree" : "MergeTree()"
  let fieldDefinitions = entityConfig.table.fields->Array.filterMap(field => {
    switch field {
    | Field(field) =>
      Some({
        let fieldName = field->Table.getClickHouseDbFieldName
        let clickHouseType = getClickHouseFieldType(
          ~fieldType=field.fieldType,
          ~isNullable=field.isNullable,
          ~isArray=field.isArray,
        )
        `\`${fieldName}\` ${clickHouseType}`
      })
    | DerivedFrom(_) => None
    }
  })

  let (partitionBy, orderBy, ttl) = switch entityConfig.storage.clickhouseOptions {
  | Some(options) => (options.partitionBy, options.orderBy, options.ttl)
  | None => (None, None, None)
  }

  // Schema field name -> ClickHouse column name, so @storage(clickhouse: {...})
  // options can reference fields the way they're written in the schema and get
  // renames (`column_name_format: snake_case`) and linked-entity `_id` suffixes
  // resolved here.
  let columnByFieldName = Dict.make()
  entityConfig.table.fields->Array.forEach(field =>
    switch field {
    | Field(f) => columnByFieldName->Dict.set(f.fieldName, f->Table.getClickHouseDbFieldName)
    | DerivedFrom(_) => ()
    }
  )

  let orderByColumns = switch orderBy {
  | Some(fieldNames) =>
    // envio_checkpoint_id stays appended so the sorting key keeps a
    // deterministic tie-break and the view's checkpoint dedup gets a clean
    // ascending run per prefix. id is dropped: ClickHouse entities are
    // read-only, so nothing looks history rows up by id.
    let userColumns =
      fieldNames
      ->Array.map(fieldName =>
        switch columnByFieldName->Dict.get(fieldName) {
        | Some(column) => `\`${column}\``
        | None =>
          // Validated at codegen, so a miss means the schema and the
          // persisted config diverged.
          JsError.throwWithMessage(
            `ClickHouse orderBy field "${fieldName}" is not defined on entity "${entityConfig.name}"`,
          )
        }
      )
      ->Array.joinUnsafe(", ")
    `${userColumns}, ${EntityHistory.checkpointIdFieldName}`
  | None => `${Table.idFieldName}, ${EntityHistory.checkpointIdFieldName}`
  }

  // partitionBy/ttl are raw ClickHouse expressions. Rewrite any bare identifier
  // that names an entity field to that field's ClickHouse column, leaving
  // functions, keywords, numbers, string literals and already-backticked
  // identifiers untouched (a quoted token never matches a bare field name).
  let resolveExpressionColumns = expression =>
    expression->String.replaceRegExpBy0Unsafe(/'[^']*'|`[^`]*`|[A-Za-z_][A-Za-z0-9_]*/g, (
      ~match,
      ~offset as _,
      ~input as _,
    ) =>
      switch columnByFieldName->Dict.get(match) {
      | Some(column) => `\`${column}\``
      | None => match
      }
    )

  let partitionByClause = switch partitionBy {
  | Some(expression) => `\nPARTITION BY ${expression->resolveExpressionColumns}`
  | None => ""
  }
  let ttlClause = switch ttl {
  | Some(expression) => `\nTTL ${expression->resolveExpressionColumns}`
  | None => ""
  }

  `CREATE TABLE IF NOT EXISTS ${database}.\`${EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )}\`${onClusterClause(~onCluster)} (
  ${fieldDefinitions->Array.joinUnsafe(",\n  ")},
  \`${EntityHistory.checkpointIdFieldName}\` ${getClickHouseFieldType(
      ~fieldType=UInt64,
      ~isNullable=false,
      ~isArray=false,
    )},
  \`${EntityHistory.changeFieldName}\` ${getClickHouseFieldType(
      ~fieldType=Enum({config: EntityHistory.RowAction.config->Table.fromGenericEnumConfig}),
      ~isNullable=false,
      ~isArray=false,
    )}
)
ENGINE = ${tableEngine}${partitionByClause}
ORDER BY (${orderByColumns})${ttlClause}`
}

// Generate CREATE TABLE query for checkpoints
let makeCreateCheckpointsTableQuery = (
  ~database: string,
  ~replicated: bool=false,
  ~onCluster: bool=false,
) => {
  let tableEngine = replicated ? "ReplicatedMergeTree" : "MergeTree()"
  let idField = (#id: InternalTable.Checkpoints.field :> string)
  let chainIdField = (#chain_id: InternalTable.Checkpoints.field :> string)
  let blockNumberField = (#block_number: InternalTable.Checkpoints.field :> string)
  let blockHashField = (#block_hash: InternalTable.Checkpoints.field :> string)
  let eventsProcessedField = (#events_processed: InternalTable.Checkpoints.field :> string)

  `CREATE TABLE IF NOT EXISTS ${database}.\`${InternalTable.Checkpoints.table.tableName}\`${onClusterClause(
      ~onCluster,
    )} (
  \`${idField}\` ${getClickHouseFieldType(~fieldType=UInt64, ~isNullable=false, ~isArray=false)},
  \`${chainIdField}\` ${getClickHouseFieldType(
      ~fieldType=Int32,
      ~isNullable=false,
      ~isArray=false,
    )},
  \`${blockNumberField}\` ${getClickHouseFieldType(
      ~fieldType=Int32,
      ~isNullable=false,
      ~isArray=false,
    )},
  \`${blockHashField}\` ${getClickHouseFieldType(
      ~fieldType=String,
      ~isNullable=true,
      ~isArray=false,
    )},
  \`${eventsProcessedField}\` ${getClickHouseFieldType(
      ~fieldType=UInt64,
      ~isNullable=false,
      ~isArray=false,
    )}
)
ENGINE = ${tableEngine}
ORDER BY (${idField})`
}

// Generate CREATE VIEW query for entity current state
let makeCreateViewQuery = (
  ~entityConfig: Internal.entityConfig,
  ~database: string,
  ~onCluster: bool=false,
) => {
  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )

  let checkpointsTableName = InternalTable.Checkpoints.table.tableName
  let checkpointIdField = (#id: InternalTable.Checkpoints.field :> string)

  let entityFields =
    entityConfig.table.fields
    ->Array.filterMap(field => {
      switch field {
      | Field(field) => {
          let fieldName = field->Table.getClickHouseDbFieldName
          Some(`\`${fieldName}\``)
        }
      | DerivedFrom(_) => None
      }
    })
    ->Array.joinUnsafe(", ")

  `CREATE VIEW IF NOT EXISTS ${database}.\`${entityConfig.name}\`${onClusterClause(~onCluster)} AS
SELECT ${entityFields}
FROM (
  SELECT ${entityFields}, \`${EntityHistory.changeFieldName}\`
  FROM ${database}.\`${historyTableName}\`
  WHERE \`${EntityHistory.checkpointIdFieldName}\` <= (SELECT max(${checkpointIdField}) FROM ${database}.\`${checkpointsTableName}\`)
  ORDER BY \`${EntityHistory.checkpointIdFieldName}\` DESC
  LIMIT 1 BY \`${Table.idFieldName}\`
)
WHERE \`${EntityHistory.changeFieldName}\` = '${(EntityHistory.RowAction.SET :> string)}'`
}

// Initialize ClickHouse tables for entities
let initialize = async (
  client,
  ~database: string,
  ~entities: array<Internal.entityConfig>,
  ~enums as _: array<Table.enumConfig<Table.enum>>,
) => {
  try {
    let databaseEngine = Env.ClickHouse.databaseEngine()
    let databaseEngineClause = switch databaseEngine {
    | Some(engine) => ` ENGINE = ${engine}`
    | None => ""
    }
    let hasReplicatedDatabaseEngine = switch databaseEngine {
    | Some(engine) => engine->databaseEngineName === "Replicated"
    | None => false
    }
    let envReplicated = Env.ClickHouse.replicated()
    // A Replicated database engine only replicates data when its tables use the
    // ReplicatedMergeTree engine, so it implies replicated mode even when
    // ENVIO_CLICKHOUSE_REPLICATED is unset.
    let replicated = envReplicated || hasReplicatedDatabaseEngine
    if hasReplicatedDatabaseEngine && !envReplicated {
      Logging.info(
        "ENVIO_CLICKHOUSE_DATABASE_ENGINE is Replicated; enabling replicated mode so tables use the ReplicatedMergeTree engine.",
      )
    }
    let databaseOnClusterClause = onClusterClause(~onCluster=replicated)
    // DDL that a Replicated database engine propagates itself must not carry
    // ON CLUSTER on top of it — the clause is only for the plain-database case.
    let ddlOnCluster = replicated && !hasReplicatedDatabaseEngine

    switch databaseEngine {
    | Some(engineSpec) => {
        let expectedEngineName = engineSpec->databaseEngineName
        let existingResult = await client->query({
          query: `SELECT engine FROM system.databases WHERE name = '${database}'`,
        })
        let rows = (await existingResult->json)["data"]
        switch rows->Array.get(0) {
        | Some(row) if row["engine"] !== expectedEngineName =>
          JsError.throwWithMessage(
            `ClickHouse database "${database}" exists with engine "${row["engine"]}" but ENVIO_CLICKHOUSE_DATABASE_ENGINE specifies "${expectedEngineName}". Drop the database manually to change its engine.`,
          )
        | _ => ()
        }
      }
    | None => ()
    }

    if hasReplicatedDatabaseEngine {
      // TRUNCATE DATABASE is unsupported on Replicated databases, so a reset
      // has to DROP and recreate instead (plain databases keep the TRUNCATE
      // fallback below). This requires the ClickHouse user to hold the DROP
      // privilege; without it the reset fails here with ACCESS_DENIED. ON
      // CLUSTER removes the database from every node — the engine's own log
      // can't replicate the drop of the database it lives in — and SYNC waits
      // for the drop to finish before the CREATE below.
      await client->exec({
        query: `DROP DATABASE IF EXISTS ${database} ON CLUSTER '{cluster}' SYNC`,
      })
    } else {
      await client->exec({
        query: `TRUNCATE DATABASE IF EXISTS ${database}${onClusterClause(~onCluster=ddlOnCluster)}`,
      })
    }
    await client->exec({
      query: `CREATE DATABASE IF NOT EXISTS ${database}${databaseOnClusterClause}${databaseEngineClause}`,
    })

    await Promise.all(
      entities->Array.map(entityConfig =>
        client->exec({
          query: makeCreateHistoryTableQuery(
            ~entityConfig,
            ~database,
            ~replicated,
            ~onCluster=ddlOnCluster,
          ),
        })
      ),
    )->Utils.Promise.ignoreValue
    await client->exec({
      query: makeCreateCheckpointsTableQuery(~database, ~replicated, ~onCluster=ddlOnCluster),
    })

    // The client pools HTTP connections, so consecutive statements may reach
    // different replicas, while a Replicated database applies DDL from its
    // Keeper log asynchronously. A CREATE VIEW is analyzed against the node's
    // local metadata and can land on a replica that hasn't applied the table
    // creates yet, failing with UNKNOWN_TABLE. Block until every replica has
    // caught up before creating the views. ON CLUSTER must precede the
    // database name in this command's grammar.
    if hasReplicatedDatabaseEngine {
      await client->exec({
        query: `SYSTEM SYNC DATABASE REPLICA ON CLUSTER '{cluster}' ${database}`,
      })
    }

    await Promise.all(
      entities->Array.map(entityConfig =>
        client->exec({
          query: makeCreateViewQuery(~entityConfig, ~database, ~onCluster=ddlOnCluster),
        })
      ),
    )->Utils.Promise.ignoreValue

    Logging.trace("ClickHouse storage initialization completed successfully")
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to initialize ClickHouse storage")
      JsError.throwWithMessage("ClickHouse initialization failed")
    }
  }
}

// Resume ClickHouse sink after reorg by deleting rows with checkpoint IDs higher than target
let resume = async (client, ~database: string, ~checkpointId: Internal.checkpointId) => {
  try {
    // Try to use the database - will throw if it doesn't exist
    try {
      await client->exec({query: `USE ${database}`})
    } catch {
    | exn =>
      Logging.errorWithExn(
        exn,
        `ClickHouse storage database "${database}" not found. Please run 'envio start -r' to reinitialize the indexer (it'll also drop Postgres database).`,
      )
      JsError.throwWithMessage("ClickHouse resume failed")
    }

    // Get all history tables
    let tablesResult = await client->query({
      query: `SHOW TABLES FROM ${database} LIKE '${EntityHistory.historyTablePrefix}%'`,
    })
    let tables = (await tablesResult->json)["data"]

    // Delete rows with checkpoint IDs higher than the target for each history table
    await Promise.all(
      tables->Array.map(table => {
        let tableName = table["name"]
        client->exec({
          query: `ALTER TABLE ${database}.\`${tableName}\` DELETE WHERE \`${EntityHistory.checkpointIdFieldName}\` > ${checkpointId->BigInt.toString}`,
        })
      }),
    )->Utils.Promise.ignoreValue

    // Delete stale checkpoints
    await client->exec({
      query: `DELETE FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\` WHERE \`${Table.idFieldName}\` > ${checkpointId->BigInt.toString}`,
    })
  } catch {
  | Persistence.StorageError(_) as exn => throw(exn)
  | exn => {
      Logging.errorWithExn(exn, "Failed to resume ClickHouse storage")
      JsError.throwWithMessage("ClickHouse resume failed")
    }
  }
}
