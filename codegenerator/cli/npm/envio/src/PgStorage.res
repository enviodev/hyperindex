let makeCreateIndexSqlUnsafe = (~tableName, ~indexFields, ~pgSchema) => {
  let indexName = tableName ++ "_" ++ indexFields->Js.Array2.joinWith("_")
  let index = indexFields->Belt.Array.map(idx => `"${idx}"`)->Js.Array2.joinWith(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON "${pgSchema}"."${tableName}"(${index}); `
}

let makeCreateTableIndicesSqlUnsafe = (table: Table.table, ~pgSchema) => {
  open Belt
  let tableName = table.tableName
  let createIndex = indexField =>
    makeCreateIndexSqlUnsafe(~tableName, ~indexFields=[indexField], ~pgSchema)
  let createCompositeIndex = indexFields => {
    makeCreateIndexSqlUnsafe(~tableName, ~indexFields, ~pgSchema)
  }

  let singleIndices = table->Table.getSingleIndices
  let compositeIndices = table->Table.getCompositeIndices

  singleIndices->Array.map(createIndex)->Js.Array2.joinWith("\n") ++
    compositeIndices->Array.map(createCompositeIndex)->Js.Array2.joinWith("\n")
}

let makeCreateTableSqlUnsafe = (table: Table.table, ~pgSchema) => {
  open Belt
  let fieldsMapped =
    table
    ->Table.getFields
    ->Array.map(field => {
      let {fieldType, isNullable, isArray, defaultValue} = field
      let fieldName = field->Table.getDbFieldName

      {
        `"${fieldName}" ${switch fieldType {
          | Custom(name) if !(name->Js.String2.startsWith("NUMERIC(")) => `"${pgSchema}".${name}`
          | _ => (fieldType :> string)
          }}${isArray ? "[]" : ""}${switch defaultValue {
          | Some(defaultValue) => ` DEFAULT ${defaultValue}`
          | None => isNullable ? `` : ` NOT NULL`
          }}`
      }
    })
    ->Js.Array2.joinWith(", ")

  let primaryKeyFieldNames = table->Table.getPrimaryKeyFieldNames
  let primaryKey =
    primaryKeyFieldNames
    ->Array.map(field => `"${field}"`)
    ->Js.Array2.joinWith(", ")

  `CREATE TABLE IF NOT EXISTS "${pgSchema}"."${table.tableName}"(${fieldsMapped}${primaryKeyFieldNames->Array.length > 0
      ? `, PRIMARY KEY(${primaryKey})`
      : ""});`
}

let makeInitializeQuery = (~pgSchema, ~staticTables, ~entities, ~enums) => {
  let allTables = staticTables->Array.copy
  let allEntityTables = []
  entities->Js.Array2.forEach((entity: Internal.entityConfig) => {
    allEntityTables->Js.Array2.push(entity.table)->ignore
    allTables->Js.Array2.push(entity.table)->ignore
    allTables->Js.Array2.push(entity.entityHistory.table)->ignore
  })
  let derivedSchema = Schema.make(allEntityTables)

  let query = ref(
    `CREATE SCHEMA IF NOT EXISTS '${pgSchema}';
GRANT ALL ON SCHEMA '${pgSchema}' TO postgres;
GRANT ALL ON SCHEMA '${pgSchema}' TO public;`,
  )

  enums->Js.Array2.forEach((enumConfig: Internal.enumConfig) => {
    query :=
      query.contents ++
      `\nIF NOT EXISTS (
  SELECT 1 
  FROM pg_type 
  WHERE typname = '${enumConfig.name->Js.String2.toLowerCase}' 
  AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = '${pgSchema}')
) THEN CREATE TYPE "${pgSchema}".${enumConfig.name} AS ENUM(${enumConfig.variants->Js.Array2.joinWith(
          ", ",
        )});`
  })

  allTables->Js.Array2.forEach((table: Table.table) => {
    query :=
      query.contents ++
      "\n" ++
      makeCreateTableSqlUnsafe(table, ~pgSchema) ++
      "\n" ++
      makeCreateTableIndicesSqlUnsafe(table, ~pgSchema)
  })

  entities->Js.Array2.forEach((entity: Internal.entityConfig) => {
    query := query.contents ++ "\n" ++ entity.entityHistory.createInsertFnQuery

    entity.table
    ->Table.getDerivedFromFields
    ->Js.Array2.forEach(derivedFromField => {
      let indexField =
        derivedSchema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn
      query :=
        query.contents ++
        "\n" ++
        makeCreateIndexSqlUnsafe(
          ~tableName=derivedFromField.derivedFromEntity,
          ~indexFields=[indexField],
          ~pgSchema,
        )
    })
  })

  `DO $$ BEGIN ${query.contents} END $$;`
}

let make = (~sql: Postgres.sql, ~pgSchema): Persistence.storage => {
  let isInitialized = async () => {
    let schemas =
      await sql->Postgres.unsafe(
        `SELECT schema_name FROM information_schema.schemata WHERE schema_name = '${pgSchema}';`,
      )
    schemas->Utils.Array.notEmpty
  }

  let initialize = async (~entities, ~staticTables, ~enums) => {
    let _ =
      await sql->Postgres.unsafe(makeInitializeQuery(~pgSchema, ~staticTables, ~entities, ~enums))
  }

  {
    isInitialized,
    initialize,
  }
}
