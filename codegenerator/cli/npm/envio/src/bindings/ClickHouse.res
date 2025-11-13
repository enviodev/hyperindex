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

// Type mapping from PostgreSQL/Table.fieldType to ClickHouse types
let mapFieldTypeToClickHouse = (fieldType: Table.fieldType, ~isNullable: bool): string => {
  let baseType = switch fieldType {
  | Int32 => "Int32"
  | BigInt({}) => "Int64" // FIXME: This is not correct, we need to use higher precision
  | Boolean => "UInt8"
  | Float8 => "Float64" // FIXME: This is not correct, we need to use higher precision
  | String => "String"
  | Serial => "Int32"
  | Json => "String"
  | Date => "DateTime64(3, 'UTC')"
  | Enum(_) => "String"
  | Entity(_) => "String"
  | BigDecimal({}) => "Decimal128"
  }

  isNullable ? `Nullable(${baseType})` : baseType
}

// Generate CREATE TABLE query for entity history table
let makeClickHouseHistoryTableQuery = (entity: Internal.entityConfig, ~database: string): option<
  string,
> => {
  let historyTable = entity.entityHistory.table

  // Filter out array fields
  let validFields =
    historyTable
    ->Table.getFields
    ->Belt.Array.keep(field => !field.isArray)

  if validFields->Belt.Array.length === 0 {
    None
  } else {
    let fieldDefinitions =
      validFields
      ->Belt.Array.map(field => {
        let fieldName = field->Table.getDbFieldName
        let clickHouseType = mapFieldTypeToClickHouse(field.fieldType, ~isNullable=field.isNullable)
        `\`${fieldName}\` ${clickHouseType}`
      })
      ->Js.Array2.joinWith(",\n  ")

    let tableName = historyTable.tableName

    Some(
      `CREATE TABLE IF NOT EXISTS ${database}.\`${tableName}\` (
  ${fieldDefinitions}
)
ENGINE = MergeTree()
ORDER BY (id, checkpoint_id)`,
    )
  }
}

// Initialize ClickHouse tables for entities
let initialize = async (
  ~host: string,
  ~database: string,
  ~username: string,
  ~password: string,
  ~entities: array<Internal.entityConfig>,
  ~enums as _: array<Internal.enumConfig<Internal.enum>>,
) => {
  let client = createClient({
    url: host,
    username,
    password,
  })

  try {
    await client->exec({query: `DROP DATABASE IF EXISTS ${database}`})
    await client->exec({query: `CREATE DATABASE ${database}`})
    await client->exec({query: `USE ${database}`})

    // Create tables for valid entities
    for i in 0 to entities->Belt.Array.length - 1 {
      let entity = entities->Belt.Array.getUnsafe(i)
      switch makeClickHouseHistoryTableQuery(entity, ~database) {
      | Some(query) => {
          Logging.trace(`Creating ClickHouse table: ${entity.name}`)
          await client->exec({query: query})
        }
      | None =>
        Logging.warn(`Skipped ClickHouse table for ${entity.name}: no valid fields after filtering`)
      }
    }

    await client->close

    Logging.trace("ClickHouse mirror initialization completed successfully")
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to initialize ClickHouse mirror")
      await client->close
      Js.Exn.raiseError("ClickHouse initialization failed")
    }
  }
}
