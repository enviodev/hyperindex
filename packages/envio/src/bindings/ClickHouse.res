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
  ~chainIdMode: ChainId.mode=Int32,
): string => {
  let baseType = switch fieldType {
  | Int32 => "Int32"
  | ChainId =>
    switch chainIdMode {
    | Int32 => "Int32"
    | Int64 => "UInt64"
    }
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
          | ChainId => ChainId.schema->S.toUnknown
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

// Column set of an entity history table, resolved once per entity and scope.
// The builders are reused across writes: filling them and staging the batch
// happens in one synchronous run, so no two writes ever hold the same builder.
type entityColumns = {
  tableName: string,
  builders: array<ClickHouseSink.builder>,
  convertSetOrThrow: Change.t<Internal.entity> => dict<unknown>,
  convertDeleteOrThrow: Change.t<Internal.entity> => dict<unknown>,
}

let compileToColumnValues = schema =>
  S.compile(
    schema,
    ~input=Value,
    ~output=Json,
    ~typeValidation=false,
    ~mode=Sync,
  )->(
    Utils.magic: (Change.t<Internal.entity> => JSON.t) => Change.t<Internal.entity> => dict<unknown>
  )

let makeEntityColumns = (
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
  ~chainIdMode: ChainId.mode,
): entityColumns => {
  let chainIdField = entityConfig.table->Table.getChainIdField
  let scopeChainId = scope->Internal.chainScopeChainId
  let idSchema = entityConfig.table->Table.getIdSchema

  let builders = entityConfig.table.fields->Array.filterMap(field =>
    switch field {
    | Table.Field(f) =>
      Some(
        ClickHouseSink.makeBuilder(
          ~name=f->Table.getClickHouseDbFieldName,
          ~kind=ClickHouseSink.kindOfField(
            ~fieldType=f.fieldType,
            ~isArray=f.isArray,
            ~chainIdMode,
          ),
        ),
      )
    | DerivedFrom(_) => None
    }
  )
  builders->Array.push(
    ClickHouseSink.makeBuilder(~name=EntityHistory.checkpointIdFieldName, ~kind=U64),
  )
  builders->Array.push(ClickHouseSink.makeBuilder(~name=EntityHistory.changeFieldName, ~kind=Text))

  {
    tableName: EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    ),
    builders,
    convertSetOrThrow: compileToColumnValues(
      EntityHistory.makeSetUpdateSchema(~idSchema, makeClickHouseEntitySchema(entityConfig.table)),
    ),
    // A delete row carries no entity to stamp, so the chain id is baked into
    // the schema instead — which is why the cache is keyed per scope. Every
    // other column is absent and takes its ClickHouse default.
    convertDeleteOrThrow: compileToColumnValues(
      S.object(s => {
        s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
        switch (chainIdField, scopeChainId) {
        | (Some(field), Some(chainId)) => s.tag(field->Table.getClickHouseDbFieldName, chainId)
        | _ => ()
        }
        Change.Delete({
          entityId: s.field(Table.idFieldName, idSchema),
          checkpointId: s.field(
            EntityHistory.checkpointIdFieldName,
            EntityHistory.unsafeCheckpointIdSchema,
          ),
        })
      }),
    ),
  }
}

// Stages the filled builders and awaits the insert. Kept separate so the caller
// can fill and stage without an await in between.
let insertBuilders = async (sink, ~tableName, ~builders: array<ClickHouseSink.builder>, ~rows) => {
  let handle =
    sink->ClickHouseSink.stage(
      ~table=tableName,
      ~rows,
      ~columns=builders->Array.map(ClickHouseSink.builderPayload),
    )
  let warnings = await sink->ClickHouseSink.flush(handle)
  warnings->Array.forEach(msg =>
    logger->Logging.childWarn({
      "msg": msg,
      "table": tableName,
    })
  )
}

let setCheckpointsOrThrow = async (sink, ~batch: Batch.t, ~chainIdMode: ChainId.mode) => {
  let rows = batch.checkpointIds->Array.length
  if rows === 0 {
    ()
  } else {
    let tableName = InternalTable.Checkpoints.table.tableName
    // Kinds mirror `makeCreateCheckpointsTableQuery`, where events_processed is
    // widened to UInt64 rather than the Int32 the Postgres table uses.
    let id = ClickHouseSink.makeBuilder(~name="id", ~kind=U64)
    let chainId = ClickHouseSink.makeBuilder(
      ~name="chain_id",
      ~kind=ClickHouseSink.kindOfField(~fieldType=ChainId, ~isArray=false, ~chainIdMode),
    )
    let blockNumber = ClickHouseSink.makeBuilder(~name="block_number", ~kind=F64)
    let blockHash = ClickHouseSink.makeBuilder(~name="block_hash", ~kind=Text)
    let eventsProcessed = ClickHouseSink.makeBuilder(~name="events_processed", ~kind=U64)
    let builders = [id, chainId, blockNumber, blockHash, eventsProcessed]
    builders->Array.forEach(builder => builder->ClickHouseSink.allocBuilder(~rows))

    for row in 0 to rows - 1 {
      id->ClickHouseSink.writeValue(
        ~row,
        batch.checkpointIds->Array.getUnsafe(row)->(Utils.magic: bigint => unknown),
      )
      chainId->ClickHouseSink.writeValue(
        ~row,
        batch.checkpointChainIds->Array.getUnsafe(row)->(Utils.magic: ChainId.t => unknown),
      )
      blockNumber->ClickHouseSink.writeValue(
        ~row,
        batch.checkpointBlockNumbers->Array.getUnsafe(row)->(Utils.magic: int => unknown),
      )
      blockHash->ClickHouseSink.writeValue(
        ~row,
        batch.checkpointBlockHashes->Array.getUnsafe(row)->(Utils.magic: Null.t<string> => unknown),
      )
      eventsProcessed->ClickHouseSink.writeValue(
        ~row,
        batch.checkpointEventsProcessed->Array.getUnsafe(row)->(Utils.magic: int => unknown),
      )
    }

    try {
      await sink->insertBuilders(~tableName, ~builders, ~rows)
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to insert checkpoints into ClickHouse table "${tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

let setUpdatesOrThrow = async (
  sink,
  ~cache: dict<entityColumns>,
  ~changes: array<Change.t<Internal.entity>>,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
  ~chainIdMode: ChainId.mode,
) => {
  let rows = changes->Array.length
  if rows === 0 {
    ()
  } else {
    let cacheKey = `${entityConfig.name}|${scope->Internal.chainScopeToString}`
    let {tableName, builders, convertSetOrThrow, convertDeleteOrThrow} = switch cache
    ->Utils.Dict.dangerouslyGetNonOption(cacheKey) {
    | Some(cached) => cached
    | None =>
      let cached = makeEntityColumns(~entityConfig, ~scope, ~chainIdMode)
      cache->Dict.set(cacheKey, cached)
      cached
    }

    let stampFieldName = switch (
      entityConfig.table->Table.getChainIdField,
      scope->Internal.chainScopeChainId,
    ) {
    | (Some(field), Some(chainId)) => Some((field.fieldName, chainId))
    | _ => None
    }

    let handle = try {
      builders->Array.forEach(builder => builder->ClickHouseSink.allocBuilder(~rows))
      for row in 0 to rows - 1 {
        let change = changes->Array.getUnsafe(row)
        // The entity history table is the source of truth for ClickHouse, so
        // every intermediate change must be persisted, not only the current value.
        let values = switch change {
        | Change.Set(set) =>
          let change = switch stampFieldName {
          | Some((fieldName, chainId)) =>
            Change.Set({
              ...set,
              entity: set.entity->Internal.stampChainId(~fieldName, ~chainId),
            })
          | None => change
          }
          convertSetOrThrow(change)
        | Delete(_) => convertDeleteOrThrow(change)
        }
        builders->Array.forEach(builder =>
          builder->ClickHouseSink.writeValue(~row, values->Dict.getUnsafe(builder.name))
        )
      }
      sink->ClickHouseSink.stage(
        ~table=tableName,
        ~rows,
        ~columns=builders->Array.map(ClickHouseSink.builderPayload),
      )
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to convert items for ClickHouse table "${tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }

    try {
      let warnings = await sink->ClickHouseSink.flush(handle)
      warnings->Array.forEach(msg =>
        logger->Logging.childWarn({
          "msg": msg,
          "table": tableName,
        })
      )
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
  ~chainIdMode: ChainId.mode=Int32,
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
          ~chainIdMode,
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
  ~chainIdMode: ChainId.mode=Int32,
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
      ~fieldType=ChainId,
      ~isNullable=false,
      ~isArray=false,
      ~chainIdMode,
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

  // A per-chain entity's rows are only comparable within a chain, so the
  // current-state dedup keys on (id, chain id).
  let dedupKey =
    switch entityConfig.table->Table.getChainIdField {
    | Some(field) => [Table.idFieldName, field->Table.getClickHouseDbFieldName]
    | None => [Table.idFieldName]
    }
    ->Array.map(name => `\`${name}\``)
    ->Array.joinUnsafe(", ")

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
  LIMIT 1 BY ${dedupKey}
)
WHERE \`${EntityHistory.changeFieldName}\` = '${(EntityHistory.RowAction.SET :> string)}'`
}

// Initialize ClickHouse tables for entities
let initialize = async (
  client,
  ~sink: ClickHouseSink.t,
  ~database: string,
  ~entities: array<Internal.entityConfig>,
  ~enums as _: array<Table.enumConfig<Table.enum>>,
  ~chainIdMode: ChainId.mode=Int32,
) => {
  // A reset drops and recreates the tables, so any column types the sink read
  // earlier in this process no longer describe them.
  entities->Array.forEach(entityConfig =>
    sink->ClickHouseSink.invalidateSchema(
      EntityHistory.historyTableName(
        ~entityName=entityConfig.name,
        ~entityIndex=entityConfig.index,
      ),
    )
  )
  sink->ClickHouseSink.invalidateSchema(InternalTable.Checkpoints.table.tableName)

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
            ~chainIdMode,
          ),
        })
      ),
    )->Utils.Promise.ignoreValue
    await client->exec({
      query: makeCreateCheckpointsTableQuery(
        ~database,
        ~replicated,
        ~onCluster=ddlOnCluster,
        ~chainIdMode,
      ),
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
