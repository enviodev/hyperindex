// ClickHouse table shapes and the statements that create them. Everything is
// sent through the Rust sink — one client, so the DDL and the inserts share a
// connection pool, a timeout policy and a TLS trust store.

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
      // Numbered explicitly, because RowBinary carries the number rather than
      // the name: leaving it to ClickHouse's own numbering would make the
      // encoder depend on a server rule instead of on this string.
      let enumValues =
        config.variants
        ->Array.mapWithIndex((variant, index) => {
          let variantStr = variant->(Utils.magic: 'a => string)
          `'${variantStr}' = ${(index + 1)->Int.toString}`
        })
        ->Array.join(", ")
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

// Warnings reach the logger as they happen: a retry storm runs inside a single
// write, so anything handed back at the end would only be read once it is over.
let makeSink = (~host, ~username, ~password, ~database) =>
  ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~onWarning=msg =>
    logger->Logging.childWarn({"msg": msg})
  )

// The two columns every history table carries beyond the entity's own. Shared
// with the DDL so the type the encoder is handed is the one the column was
// created with.
let checkpointIdClickHouseType = getClickHouseFieldType(
  ~fieldType=UInt64,
  ~isNullable=false,
  ~isArray=false,
)
let changeClickHouseType = getClickHouseFieldType(
  ~fieldType=Enum({config: EntityHistory.RowAction.config->Table.fromGenericEnumConfig}),
  ~isNullable=false,
  ~isArray=false,
)

// The checkpoints table as ClickHouse holds it, in column order. The DDL, the
// insert's column list and the values it sends all come from this one list, so a
// column cannot be declared in one and forgotten in another — nor, worse, end up
// paired with a different column's values, which nothing downstream could catch:
// every array reaches the builders as `unknown`.
// `events_processed` is widened here rather than taken from
// `InternalTable.Checkpoints.table`, whose Int32 is what Postgres stores.
type checkpointColumn = {
  name: string,
  fieldType: Table.fieldType,
  isNullable: bool,
  valuesOf: Batch.t => array<unknown>,
}

let checkpointColumns: array<checkpointColumn> = [
  {
    name: (#id: InternalTable.Checkpoints.field :> string),
    fieldType: UInt64,
    isNullable: false,
    valuesOf: batch => batch.checkpointIds->(Utils.magic: array<bigint> => array<unknown>),
  },
  {
    name: (#chain_id: InternalTable.Checkpoints.field :> string),
    fieldType: ChainId,
    isNullable: false,
    valuesOf: batch => batch.checkpointChainIds->(Utils.magic: array<ChainId.t> => array<unknown>),
  },
  {
    name: (#block_number: InternalTable.Checkpoints.field :> string),
    fieldType: Int32,
    isNullable: false,
    valuesOf: batch => batch.checkpointBlockNumbers->(Utils.magic: array<int> => array<unknown>),
  },
  {
    name: (#block_hash: InternalTable.Checkpoints.field :> string),
    fieldType: String,
    isNullable: true,
    valuesOf: batch =>
      batch.checkpointBlockHashes->(Utils.magic: array<Null.t<string>> => array<unknown>),
  },
  {
    name: (#events_processed: InternalTable.Checkpoints.field :> string),
    fieldType: UInt64,
    isNullable: false,
    valuesOf: batch => batch.checkpointEventsProcessed->(Utils.magic: array<int> => array<unknown>),
  },
]

// The checkpoints table's columns as the sink registers and the DDL declares
// them. One derivation, so a column cannot be created with one type and encoded
// against another.
let checkpointColumnSpecs = (~chainIdMode: ChainId.mode): array<ClickHouseSink.columnSpec> =>
  checkpointColumns->Array.map(({name, fieldType, isNullable}) => {
    ClickHouseSink.name,
    chType: getClickHouseFieldType(~fieldType, ~isNullable, ~isArray=false, ~chainIdMode),
  })

// Every column envio declares on an entity's history table, in DDL order. The
// CREATE TABLE and the sink's registration both read this, so a column is
// encoded against the type it was created with.
let entityColumnTypes = (~entityConfig: Internal.entityConfig, ~chainIdMode: ChainId.mode): array<(
  string,
  string,
)> => {
  let columns = entityConfig.table.fields->Array.filterMap(field =>
    switch field {
    | Table.Field(f) =>
      Some((
        f->Table.getClickHouseDbFieldName,
        getClickHouseFieldType(
          ~fieldType=f.fieldType,
          ~isNullable=f.isNullable,
          ~isArray=f.isArray,
          ~chainIdMode,
        ),
      ))
    | DerivedFrom(_) => None
    }
  )
  columns->Array.push((EntityHistory.checkpointIdFieldName, checkpointIdClickHouseType))
  columns->Array.push((EntityHistory.changeFieldName, changeClickHouseType))
  columns
}

let entityColumnSpecs = (~entityConfig, ~chainIdMode): array<ClickHouseSink.columnSpec> =>
  entityColumnTypes(~entityConfig, ~chainIdMode)->Array.map(((name, chType)) => {
    ClickHouseSink.name,
    chType,
  })

// The compiled serializers for one entity and chain scope. Only these vary with
// the scope; the column set does not, so the registered table is shared.
type converters = {
  convertSetOrThrow: Change.t<Internal.entity> => dict<unknown>,
  convertDeleteOrThrow: Change.t<Internal.entity> => dict<unknown>,
}

// What a sink needs to write: the tables it has registered, and the serializers
// it has compiled. The chain-id mode is the only thing column types vary with
// and it is fixed for the sink, so it lives here rather than on every call.
type registry = {
  chainIdMode: ChainId.mode,
  entities: dict<ClickHouseSink.table>,
  mutable checkpoints: option<ClickHouseSink.table>,
  converters: dict<converters>,
}

let makeRegistry = (~chainIdMode) => {
  chainIdMode,
  entities: Dict.make(),
  checkpoints: None,
  converters: Dict.make(),
}

let compileToColumnValues = schema =>
  S.compile(schema, ~input=Value, ~output=Json, ~typeValidation=false, ~mode=Sync)->(
    Utils.magic: (Change.t<Internal.entity> => JSON.t) => Change.t<Internal.entity> => dict<unknown>
  )

let makeConverters = (
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
): converters => {
  let chainIdField = entityConfig.table->Table.getChainIdField
  let scopeChainId = scope->Internal.chainScopeChainId
  let idSchema = entityConfig.table->Table.getIdSchema

  {
    convertSetOrThrow: compileToColumnValues(
      EntityHistory.makeSetUpdateSchema(~idSchema, makeClickHouseEntitySchema(entityConfig.table)),
    ),
    // A delete row carries no entity to stamp, so the chain id is baked into
    // the schema instead — which is why these are cached per scope. Every
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

// Registering parses the column types, which is where a type this encoder
// cannot hold is refused. `initialize` warms every table so that lands at
// startup, but an indexer resuming an existing storage never runs it — so the
// write path registers on demand rather than depending on that.
let entityTable = (sink, ~registry, ~entityConfig: Internal.entityConfig) =>
  switch registry.entities->Utils.Dict.dangerouslyGetNonOption(entityConfig.name) {
  | Some(table) => table
  | None =>
    let table =
      sink->ClickHouseSink.registerTableOrThrow(
        ~table=EntityHistory.historyTableName(
          ~entityName=entityConfig.name,
          ~entityIndex=entityConfig.index,
        ),
        ~columns=entityColumnSpecs(~entityConfig, ~chainIdMode=registry.chainIdMode),
      )
    registry.entities->Dict.set(entityConfig.name, table)
    table
  }

let checkpointsTable = (sink, ~registry) =>
  switch registry.checkpoints {
  | Some(table) => table
  | None =>
    let table =
      sink->ClickHouseSink.registerTableOrThrow(
        ~table=InternalTable.Checkpoints.table.tableName,
        ~columns=checkpointColumnSpecs(~chainIdMode=registry.chainIdMode),
      )
    registry.checkpoints = Some(table)
    table
  }

// Copies the batch into the sink and returns the handle to write. Splitting
// staging from the write is what lets the values be read on the JS thread while
// the encode and the round trip happen off it.
let stageBuilders = (sink, ~table: ClickHouseSink.table, ~builders, ~rows) =>
  sink->ClickHouseSink.stage(
    ~table=table.handle,
    ~rows,
    ~columns=builders->Array.map(ClickHouseSink.builderPayload),
  )

let stageCheckpointsOrThrow = (sink, ~registry, ~batch: Batch.t) => {
  let rows = batch.checkpointIds->Array.length
  if rows === 0 {
    Null.null
  } else {
    let table = sink->checkpointsTable(~registry)
    let values = checkpointColumns->Array.map(({valuesOf}) => valuesOf(batch))
    try {
      let builders = table.columns->Array.map(ClickHouseSink.makeBuilder(_, ~rows))
      // A checkpoint id past what UInt64 holds is refused here rather than being
      // reduced to a different id by the typed array it would land in.
      builders->Array.forEachWithIndex((builder, column) => {
        let columnValues = values->Array.getUnsafe(column)
        for row in 0 to rows - 1 {
          builder->ClickHouseSink.writeValue(~row, columnValues->Array.getUnsafe(row))
        }
      })
      Null.make(sink->stageBuilders(~table, ~builders, ~rows))
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to convert checkpoints for ClickHouse table "${table.name}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

let stageUpdatesOrThrow = (
  sink,
  ~registry,
  ~changes: array<Change.t<Internal.entity>>,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
) => {
  let rows = changes->Array.length
  if rows === 0 {
    None
  } else {
    let table = sink->entityTable(~registry, ~entityConfig)
    let tableName = table.name
    let cacheKey = `${entityConfig.name}|${scope->Internal.chainScopeToString}`
    let {convertSetOrThrow, convertDeleteOrThrow} = switch registry.converters
    ->Utils.Dict.dangerouslyGetNonOption(cacheKey) {
    | Some(cached) => cached
    | None =>
      let cached = makeConverters(~entityConfig, ~scope)
      registry.converters->Dict.set(cacheKey, cached)
      cached
    }

    let stampFieldName = switch (
      entityConfig.table->Table.getChainIdField,
      scope->Internal.chainScopeChainId,
    ) {
    | (Some(field), Some(chainId)) => Some((field.fieldName, chainId))
    | _ => None
    }

    try {
      let builders = table.columns->Array.map(ClickHouseSink.makeBuilder(_, ~rows))
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
      Some(sink->stageBuilders(~table, ~builders, ~rows))
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to convert items for ClickHouse table "${tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Sends every staged batch, then the checkpoints that cover them. The ordering
// is Rust's to keep: the current-state views read up to `max(id)` of the
// checkpoints table, so a checkpoint visible before its rows would expose a
// partial batch.
let writeStagedOrThrow = async (sink, ~entities, ~checkpoints) =>
  try await sink->ClickHouseSink.writeBatch(~entities, ~checkpoints) catch {
  | exn =>
    throw(
      Persistence.StorageError({
        message: "Failed to write a batch to ClickHouse",
        reason: exn->Utils.prettifyExn,
      }),
    )
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
  let fieldDefinitions =
    entityColumnTypes(~entityConfig, ~chainIdMode)->Array.map(((name, chType)) =>
      `\`${name}\` ${chType}`
    )

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
  ${fieldDefinitions->Array.joinUnsafe(",\n  ")}
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
  let columns =
    checkpointColumnSpecs(~chainIdMode)
    ->Array.map(({name, chType}) => `  \`${name}\` ${chType}`)
    ->Array.join(",\n")

  `CREATE TABLE IF NOT EXISTS ${database}.\`${InternalTable.Checkpoints.table.tableName}\`${onClusterClause(
      ~onCluster,
    )} (
${columns}
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
  sink,
  ~registry,
  ~database: string,
  ~entities: array<Internal.entityConfig>,
  ~enums as _: array<Table.enumConfig<Table.enum>>,
  ~chainIdMode: ChainId.mode=Int32,
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
        let existing =
          await sink->ClickHouseSink.query(
            `SELECT engine FROM system.databases WHERE name = '${database}' FORMAT TabSeparated`,
          )
        switch existing->String.trim {
        | "" => ()
        | engine if engine !== expectedEngineName =>
          JsError.throwWithMessage(
            `ClickHouse database "${database}" exists with engine "${engine}" but ENVIO_CLICKHOUSE_DATABASE_ENGINE specifies "${expectedEngineName}". Drop the database manually to change its engine.`,
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
      await sink->ClickHouseSink.exec(
        `DROP DATABASE IF EXISTS ${database} ON CLUSTER '{cluster}' SYNC`,
      )
    } else {
      await sink->ClickHouseSink.exec(
        `TRUNCATE DATABASE IF EXISTS ${database}${onClusterClause(~onCluster=ddlOnCluster)}`,
      )
    }
    await sink->ClickHouseSink.exec(
      `CREATE DATABASE IF NOT EXISTS ${database}${databaseOnClusterClause}${databaseEngineClause}`,
    )

    await Promise.all(
      entities->Array.map(entityConfig =>
        sink->ClickHouseSink.exec(
          makeCreateHistoryTableQuery(
            ~entityConfig,
            ~database,
            ~replicated,
            ~onCluster=ddlOnCluster,
            ~chainIdMode,
          ),
        )
      ),
    )->Utils.Promise.ignoreValue
    await sink->ClickHouseSink.exec(
      makeCreateCheckpointsTableQuery(~database, ~replicated, ~onCluster=ddlOnCluster, ~chainIdMode),
    )

    // The client pools HTTP connections, so consecutive statements may reach
    // different replicas, while a Replicated database applies DDL from its
    // Keeper log asynchronously. A CREATE VIEW is analyzed against the node's
    // local metadata and can land on a replica that hasn't applied the table
    // creates yet, failing with UNKNOWN_TABLE. Block until every replica has
    // caught up before creating the views. ON CLUSTER must precede the
    // database name in this command's grammar.
    if hasReplicatedDatabaseEngine {
      await sink->ClickHouseSink.exec(
        `SYSTEM SYNC DATABASE REPLICA ON CLUSTER '{cluster}' ${database}`,
      )
    }

    await Promise.all(
      entities->Array.map(entityConfig =>
        sink->ClickHouseSink.exec(
          makeCreateViewQuery(~entityConfig, ~database, ~onCluster=ddlOnCluster),
        )
      ),
    )->Utils.Promise.ignoreValue

    // Registered here rather than on first use, so a column type this encoder
    // cannot hold stops the indexer at startup, with nothing written.
    let _ = sink->checkpointsTable(~registry)
    entities->Array.forEach(entityConfig =>
      ignore(sink->entityTable(~registry, ~entityConfig))
    )

    Logging.trace("ClickHouse storage initialization completed successfully")
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to initialize ClickHouse storage")
      JsError.throwWithMessage("ClickHouse initialization failed")
    }
  }
}

// Resume ClickHouse sink after reorg by deleting rows with checkpoint IDs higher than target
let resume = async (sink, ~database: string, ~checkpointId: Internal.checkpointId) => {
  try {
    // Try to use the database - will throw if it doesn't exist
    try {
      await sink->ClickHouseSink.exec(`USE ${database}`)
    } catch {
    | exn =>
      Logging.errorWithExn(
        exn,
        `ClickHouse storage database "${database}" not found. Please run 'envio start -r' to reinitialize the indexer (it'll also drop Postgres database).`,
      )
      JsError.throwWithMessage("ClickHouse resume failed")
    }

    // Get all history tables. TabSeparated answers one name per line, which is
    // all this reads.
    let tables =
      await sink->ClickHouseSink.query(
        `SHOW TABLES FROM ${database} LIKE '${EntityHistory.historyTablePrefix}%' FORMAT TabSeparated`,
      )

    // Delete rows with checkpoint IDs higher than the target for each history table
    await Promise.all(
      tables
      ->String.split("\n")
      ->Array.filterMap(tableName =>
        switch tableName->String.trim {
        | "" => None
        | tableName =>
          Some(
            sink->ClickHouseSink.exec(
              `ALTER TABLE ${database}.\`${tableName}\` DELETE WHERE \`${EntityHistory.checkpointIdFieldName}\` > ${checkpointId->BigInt.toString}`,
            ),
          )
        }
      ),
    )->Utils.Promise.ignoreValue

    // Delete stale checkpoints
    await sink->ClickHouseSink.exec(
      `DELETE FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\` WHERE \`${Table.idFieldName}\` > ${checkpointId->BigInt.toString}`,
    )
  } catch {
  | Persistence.StorageError(_) as exn => throw(exn)
  | exn => {
      Logging.errorWithExn(exn, "Failed to resume ClickHouse storage")
      JsError.throwWithMessage("ClickHouse resume failed")
    }
  }
}
