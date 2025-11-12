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
  | Integer => "Int32"
  | BigInt => "Int64"
  | Boolean => "UInt8"
  | Numeric => "Decimal128(18)"
  | DoublePrecision => "Float64"
  | Text => "String"
  | Serial => "Int32"
  | JsonB => "String"
  | Timestamp
  | TimestampWithoutTimezone
  | TimestampWithNullTimezone => "DateTime64(3, 'UTC')"
  | Custom(name) =>
    // Check if it's a NUMERIC with precision
    if name->Js.String2.startsWith("NUMERIC(") {
      // Extract precision from NUMERIC(p, s) or use default
      name
      ->Js.String2.replace("NUMERIC", "Decimal128")
      ->Js.String2.replaceByRe(%re("/\((\d+),\s*(\d+)\)/"), "(18)")
    } else {
      // For enums and other custom types, return String as fallback
      "String"
    }
  }

  isNullable ? `Nullable(${baseType})` : baseType
}

// Helper to check if a field has an enum type
let hasEnumField = (entity: Internal.entityConfig, ~enumNames: array<string>): bool => {
  entity.table
  ->Table.getFields
  ->Belt.Array.some(field =>
    switch field.fieldType {
    | Table.Custom(name) => enumNames->Js.Array2.includes(name)
    | _ => false
    }
  )
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
  ~enums: array<Internal.enumConfig<Internal.enum>>,
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

    // Get enum names for filtering
    let enumNames = enums->Belt.Array.map(e => e.name)

    // Filter entities: skip those with enum fields or array fields
    let validEntities = entities->Belt.Array.keep(entity => {
      let hasEnums = hasEnumField(entity, ~enumNames)
      let hasArrays =
        entity.entityHistory.table
        ->Table.getFields
        ->Belt.Array.some(field => field.isArray)

      !hasEnums && !hasArrays
    })

    Logging.trace(
      `Creating ClickHouse history tables for ${validEntities
        ->Belt.Array.length
        ->Belt.Int.toString} entities (filtered ${(entities->Belt.Array.length -
          validEntities->Belt.Array.length)->Belt.Int.toString} entities with enums/arrays)`,
    )

    // Create tables for valid entities
    for i in 0 to validEntities->Belt.Array.length - 1 {
      let entity = validEntities->Belt.Array.getUnsafe(i)
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
