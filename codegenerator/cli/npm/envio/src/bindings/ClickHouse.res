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

let setOrThrow = async (
  client,
  ~items: array<'item>,
  ~table: Table.table,
  ~itemSchema: S.t<'item>,
  ~database: string,
) => {
  if items->Array.length === 0 {
    ()
  } else {
    try {
      // Convert entity updates to ClickHouse row format
      let values = items->Js.Array2.map(item => {
        item->S.reverseConvertOrThrow(itemSchema)
      })

      await client->insert({
        table: `${database}.\`${table.tableName}\``,
        values,
        format: "JSONEachRow",
      })
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert items into ClickHouse table "${table.tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
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
      entities->Belt.Array.map(entity =>
        client->exec({query: makeCreateHistoryTableQuery(entity, ~database)})
      ),
    )->Promise.ignoreValue

    Logging.trace("ClickHouse mirror initialization completed successfully")
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to initialize ClickHouse mirror")
      Js.Exn.raiseError("ClickHouse initialization failed")
    }
  }
}
