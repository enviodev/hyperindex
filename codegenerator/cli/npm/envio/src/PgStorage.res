let makeCreateIndexSqlUnsafe = (~tableName, ~indexFields, ~pgSchema) => {
  let indexName = tableName ++ "_" ++ indexFields->Js.Array2.joinWith("_")
  let index = indexFields->Belt.Array.map(idx => `"${idx}"`)->Js.Array2.joinWith(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON "${pgSchema}"."${tableName}"(${index});`
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

let makeInitializeTransaction = (
  ~pgSchema,
  ~pgUser,
  ~generalTables,
  ~entities,
  ~enums,
  ~cleanRun,
) => {
  let allTables = generalTables->Array.copy
  let allEntityTables = []
  entities->Js.Array2.forEach((entity: Internal.entityConfig) => {
    allEntityTables->Js.Array2.push(entity.table)->ignore
    allTables->Js.Array2.push(entity.table)->ignore
    allTables->Js.Array2.push(entity.entityHistory.table)->ignore
  })
  let derivedSchema = Schema.make(allEntityTables)

  let query = ref(
    (
      cleanRun
        ? `DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;
CREATE SCHEMA "${pgSchema}";`
        : `CREATE SCHEMA IF NOT EXISTS "${pgSchema}";`
    ) ++
    `GRANT ALL ON SCHEMA "${pgSchema}" TO ${pgUser};
GRANT ALL ON SCHEMA "${pgSchema}" TO public;`,
  )

  // Optimized enum creation - direct when cleanRun, conditional otherwise
  enums->Js.Array2.forEach((enumConfig: Internal.enumConfig<Internal.enum>) => {
    // Create base enum creation query once
    let enumCreateQuery = `CREATE TYPE "${pgSchema}".${enumConfig.name} AS ENUM(${enumConfig.variants
      ->Js.Array2.map(v => `'${v->(Utils.magic: Internal.enum => string)}'`)
      ->Js.Array2.joinWith(", ")});`

    query :=
      query.contents ++
      "\n" ++ if cleanRun {
        // Direct creation when cleanRunting (faster)
        enumCreateQuery
      } else {
        // Wrap with conditional check only when not cleanRunting
        `IF NOT EXISTS (
  SELECT 1 FROM pg_type 
  WHERE typname = '${enumConfig.name->Js.String2.toLowerCase}' 
  AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = '${pgSchema}')
) THEN 
    ${enumCreateQuery}
END IF;`
      }
  })

  // Batch all table creation first (optimal for PostgreSQL)
  allTables->Js.Array2.forEach((table: Table.table) => {
    query := query.contents ++ "\n" ++ makeCreateTableSqlUnsafe(table, ~pgSchema)
  })

  // Then batch all indices (better performance when tables exist)
  allTables->Js.Array2.forEach((table: Table.table) => {
    let indices = makeCreateTableIndicesSqlUnsafe(table, ~pgSchema)
    if indices !== "" {
      query := query.contents ++ "\n" ++ indices
    }
  })

  let functionsQuery = ref("")

  // Add derived indices
  entities->Js.Array2.forEach((entity: Internal.entityConfig) => {
    functionsQuery := functionsQuery.contents ++ "\n" ++ entity.entityHistory.createInsertFnQuery

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

  [
    // Return optimized queries - main DDL in DO block, functions separate
    // Note: DO $$ BEGIN wrapper is only needed for PL/pgSQL conditionals (IF NOT EXISTS)
    // Reset case uses direct DDL (faster), non-cleanRun case uses conditionals (safer)
    cleanRun || enums->Utils.Array.isEmpty
      ? query.contents
      : `DO $$ BEGIN ${query.contents} END $$;`,
    // Functions query (separate as they can't be in DO block)
  ]->Js.Array2.concat(functionsQuery.contents !== "" ? [functionsQuery.contents] : [])
}

let makeLoadByIdQuery = (~pgSchema, ~tableName) => {
  `SELECT * FROM "${pgSchema}"."${tableName}" WHERE id = $1 LIMIT 1;`
}

let makeLoadByIdsQuery = (~pgSchema, ~tableName) => {
  `SELECT * FROM "${pgSchema}"."${tableName}" WHERE id = ANY($1::text[]);`
}

let make = (~sql: Postgres.sql, ~pgSchema, ~pgUser): Persistence.storage => {
  let isInitialized = async () => {
    let schemas =
      await sql->Postgres.unsafe(
        `SELECT schema_name FROM information_schema.schemata WHERE schema_name = '${pgSchema}';`,
      )
    schemas->Utils.Array.notEmpty
  }

  let initialize = async (~entities=[], ~generalTables=[], ~enums=[], ~cleanRun=false) => {
    let queries = makeInitializeTransaction(
      ~pgSchema,
      ~pgUser,
      ~generalTables,
      ~entities,
      ~enums,
      ~cleanRun,
    )
    // Execute all queries within a single transaction for integrity
    let _ = await sql->Postgres.beginSql(sql => {
      queries->Js.Array2.map(query => sql->Postgres.unsafe(query))
    })
  }

  let loadByIdsOrThrow = async (~ids, ~table: Table.table, ~rowsSchema) => {
    switch await (
      switch ids {
      | [_] =>
        sql->Postgres.preparedUnsafe(
          makeLoadByIdQuery(~pgSchema, ~tableName=table.tableName),
          ids->Obj.magic,
        )
      | _ =>
        sql->Postgres.preparedUnsafe(
          makeLoadByIdsQuery(~pgSchema, ~tableName=table.tableName),
          [ids]->Obj.magic,
        )
      }
    ) {
    | exception exn =>
      raise(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by ids`,
          reason: exn,
        }),
      )
    | rows =>
      try rows->S.parseOrThrow(rowsSchema) catch {
      | exn =>
        raise(
          Persistence.StorageError({
            message: `Failed to parse "${table.tableName}" loaded from storage by ids`,
            reason: exn,
          }),
        )
      }
    }
  }

  {
    isInitialized,
    initialize,
    loadByIdsOrThrow,
  }
}
