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

@send
external json: queryResult<'a> => promise<'a> = "json"

let getClickHouseFieldType = (
  ~fieldType: Table.fieldType,
  ~isNullable: bool,
  ~isArray: bool,
): string => {
  let baseType = switch fieldType {
  | Int32 => "Int32"
  | Uint32 => "UInt32"
  | Serial => "Int32"
  | BigInt({?precision}) =>
    switch precision {
    | None => "String" // Fallback for unbounded BigInt
    | Some(precision) =>
      if precision > 38 {
        "String"
      } else {
        `Decimal(${precision->Js.Int.toString},0)`
      }
    }
  | BigDecimal({?config}) =>
    switch config {
    | None => "String" // Fallback for unbounded BigInt
    | Some((precision, scale)) =>
      if precision > 38 || scale > precision {
        "String"
      } else {
        `Decimal(${precision->Js.Int.toString},${scale->Js.Int.toString})`
      }
    }
  | Boolean => "Bool"
  | Number => "Float64"
  | String => "String"
  | Json => "String"
  | Date => "DateTime64(3, 'UTC')"
  | Enum({config}) => {
      let variantsLength = config.variants->Belt.Array.length
      // Theoretically we can store 256 variants in Enum8,
      // but it'd require to explicitly start with a negative index (probably)
      let enumType = variantsLength <= 127 ? "Enum8" : "Enum16"
      let enumValues =
        config.variants
        ->Belt.Array.map(variant => {
          let variantStr = variant->(Utils.magic: 'a => string)
          `'${variantStr}'`
        })
        ->Js.Array2.joinWith(", ")
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

let setCheckpointsOrThrow = async (client, ~batch: Batch.t, ~database: string) => {
  let checkpointsCount = batch.checkpointIds->Array.length
  if checkpointsCount === 0 {
    ()
  } else {
    // Convert columnar data to row format for JSONCompactEachRow
    let checkpointRows = []
    for idx in 0 to checkpointsCount - 1 {
      checkpointRows
      ->Js.Array2.push((
        batch.checkpointIds->Belt.Array.getUnsafe(idx),
        batch.checkpointChainIds->Belt.Array.getUnsafe(idx),
        batch.checkpointBlockNumbers->Belt.Array.getUnsafe(idx),
        batch.checkpointBlockHashes->Belt.Array.getUnsafe(idx),
        batch.checkpointEventsProcessed->Belt.Array.getUnsafe(idx),
      ))
      ->ignore
    }

    try {
      await client->insert({
        table: `${database}.\`${InternalTable.Checkpoints.table.tableName}\``,
        values: checkpointRows,
        format: "JSONCompactEachRow",
      })
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert checkpoints into ClickHouse table "${InternalTable.Checkpoints.table.tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

let setUpdatesOrThrow = async (
  client,
  ~updates: array<Internal.inMemoryStoreEntityUpdate<Internal.entity>>,
  ~entityConfig: Internal.entityConfig,
  ~database: string,
) => {
  if updates->Array.length === 0 {
    ()
  } else {
    let {convertOrThrow, tableName} = switch entityConfig.clickHouseSetUpdatesCache {
    | Some(cache) => cache
    | None =>
      let cache: Internal.clickHouseSetUpdatesCache = {
        tableName: `${database}.\`${EntityHistory.historyTableName(
            ~entityName=entityConfig.name,
            ~entityIndex=entityConfig.index,
          )}\``,
        convertOrThrow: S.compile(
          S.union([
            EntityHistory.makeSetUpdateSchema(entityConfig.schema),
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
          ~input=Value,
          ~output=Json,
          ~typeValidation=false,
          ~mode=Sync,
        ),
      }

      entityConfig.clickHouseSetUpdatesCache = Some(cache)
      cache
    }

    try {
      // Convert entity updates to ClickHouse row format
      let values = updates->Js.Array2.map(update => {
        update.latestChange->convertOrThrow
      })

      await client->insert({
        table: tableName,
        values,
        format: "JSONEachRow",
      })
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert items into ClickHouse table "${tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Generate CREATE TABLE query for entity history table
let makeCreateHistoryTableQuery = (~entityConfig: Internal.entityConfig, ~database: string) => {
  let fieldDefinitions = entityConfig.table.fields->Belt.Array.keepMap(field => {
    switch field {
    | Field(field) =>
      Some({
        let fieldName = field->Table.getDbFieldName
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

  `CREATE TABLE IF NOT EXISTS ${database}.\`${EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )}\` (
  ${fieldDefinitions->Js.Array2.joinWith(",\n  ")},
  \`${EntityHistory.checkpointIdFieldName}\` ${getClickHouseFieldType(
      ~fieldType=Uint32,
      ~isNullable=false,
      ~isArray=false,
    )},
  \`${EntityHistory.changeFieldName}\` ${getClickHouseFieldType(
      ~fieldType=Enum({config: EntityHistory.RowAction.config->Table.fromGenericEnumConfig}),
      ~isNullable=false,
      ~isArray=false,
    )}
)
ENGINE = MergeTree()
ORDER BY (${Table.idFieldName}, ${EntityHistory.checkpointIdFieldName})`
}

// Generate CREATE TABLE query for checkpoints
let makeCreateCheckpointsTableQuery = (~database: string) => {
  let idField = (#id: InternalTable.Checkpoints.field :> string)
  let chainIdField = (#chain_id: InternalTable.Checkpoints.field :> string)
  let blockNumberField = (#block_number: InternalTable.Checkpoints.field :> string)
  let blockHashField = (#block_hash: InternalTable.Checkpoints.field :> string)
  let eventsProcessedField = (#events_processed: InternalTable.Checkpoints.field :> string)

  `CREATE TABLE IF NOT EXISTS ${database}.\`${InternalTable.Checkpoints.table.tableName}\` (
  \`${idField}\` ${getClickHouseFieldType(~fieldType=Int32, ~isNullable=false, ~isArray=false)},
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
      ~fieldType=Int32,
      ~isNullable=false,
      ~isArray=false,
    )}
)
ENGINE = MergeTree()
ORDER BY (${idField})`
}

// Generate CREATE VIEW query for entity current state
let makeCreateViewQuery = (~entityConfig: Internal.entityConfig, ~database: string) => {
  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )

  let checkpointsTableName = InternalTable.Checkpoints.table.tableName
  let checkpointIdField = (#id: InternalTable.Checkpoints.field :> string)

  let entityFields =
    entityConfig.table.fields
    ->Belt.Array.keepMap(field => {
      switch field {
      | Field(field) => {
          let fieldName = field->Table.getDbFieldName
          Some(`\`${fieldName}\``)
        }
      | DerivedFrom(_) => None
      }
    })
    ->Js.Array2.joinWith(", ")

  `CREATE VIEW IF NOT EXISTS ${database}.\`${entityConfig.name}\` AS
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
    await client->exec({query: `DROP DATABASE IF EXISTS ${database}`})
    await client->exec({query: `CREATE DATABASE ${database}`})
    await client->exec({query: `USE ${database}`})

    await Promise.all(
      entities->Belt.Array.map(entityConfig =>
        client->exec({query: makeCreateHistoryTableQuery(~entityConfig, ~database)})
      ),
    )->Promise.ignoreValue

    await Promise.all(
      entities->Belt.Array.map(entityConfig =>
        client->exec({query: makeCreateViewQuery(~entityConfig, ~database)})
      ),
    )->Promise.ignoreValue

    await client->exec({query: makeCreateCheckpointsTableQuery(~database)})

    Logging.trace("ClickHouse sink initialization completed successfully")
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to initialize ClickHouse sink")
      Js.Exn.raiseError("ClickHouse initialization failed")
    }
  }
}

// Resume ClickHouse sink after reorg by deleting rows with checkpoint IDs higher than target
let resume = async (client, ~database: string, ~checkpointId: float) => {
  try {
    // Try to use the database - will throw if it doesn't exist
    try {
      await client->exec({query: `USE ${database}`})
    } catch {
    | exn =>
      Logging.errorWithExn(
        exn,
        `ClickHouse sink database "${database}" not found. Please run 'envio start -r' to reinitialize the indexer (it'll also drop Postgres database).`,
      )
      Js.Exn.raiseError("ClickHouse resume failed")
    }

    // Get all history tables
    let tablesResult = await client->query({
      query: `SHOW TABLES FROM ${database} LIKE '${EntityHistory.historyTablePrefix}%'`,
    })
    let tables: array<{"name": string}> = await tablesResult->json

    // Delete rows with checkpoint IDs higher than the target for each history table
    await Promise.all(
      tables->Belt.Array.map(table => {
        let tableName = table["name"]
        client->exec({
          query: `ALTER TABLE ${database}.\`${tableName}\` DELETE WHERE \`${EntityHistory.checkpointIdFieldName}\` > ${checkpointId->Belt.Float.toString}`,
        })
      }),
    )->Promise.ignoreValue
  } catch {
  | Persistence.StorageError(_) as exn => raise(exn)
  | exn => {
      Logging.errorWithExn(exn, "Failed to resume ClickHouse sink")
      Js.Exn.raiseError("ClickHouse resume failed")
    }
  }
}
