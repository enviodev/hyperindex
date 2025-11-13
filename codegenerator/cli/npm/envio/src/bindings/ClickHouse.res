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
    | None => `UInt256` // FIXME: Should use String here?
    | Some(precision) => `Decimal(${precision->Js.Int.toString},0)`
    }
  | BigDecimal({?config}) =>
    switch config {
    | None =>
      Js.Exn.raiseError(
        "Please provide a @config(precision: <precision>, scale: <scale>) directive on the BigDecimal field for ClickHouse to work correctly",
      )
    | Some((precision, scale)) => `Decimal(${precision->Js.Int.toString},${scale->Js.Int.toString})`
    }
  | Boolean => "Bool"
  | Number => "Float64"
  | String => "String"
  | Json => "String"
  | Date => "DateTime64(3, 'UTC')"
  | Enum(_) => "String"
  | Entity(_) => "String"
  }

  let baseType = if isArray {
    `Array(${baseType})`
  } else {
    baseType
  }

  isNullable ? `Nullable(${baseType})` : baseType
}

// Generate CREATE TABLE query for entity history table
let makeCreateHistoryTableQuery = (entity: Internal.entityConfig, ~database: string) => {
  let historyTable = entity.entityHistory.table

  let fieldDefinitions =
    historyTable.fields
    ->Belt.Array.keepMap(field => {
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
    ->Js.Array2.joinWith(",\n  ")

  let tableName = historyTable.tableName

  `CREATE TABLE IF NOT EXISTS ${database}.\`${tableName}\` (
  ${fieldDefinitions}
)
ENGINE = MergeTree()
ORDER BY (id, ${EntityHistory.checkpointIdFieldName})`
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

    await Promise.all(
      entities->Belt.Array.map(entity =>
        client->exec({query: makeCreateHistoryTableQuery(entity, ~database)})
      ),
    )->Promise.ignoreValue
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
