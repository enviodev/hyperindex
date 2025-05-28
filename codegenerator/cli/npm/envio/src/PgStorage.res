let makeInitializeQuery = (~pgSchema, ~entities as _, ~enums) => {
  let query = ref(
    `CREATE SCHEMA IF NOT EXISTS '${pgSchema}';
GRANT ALL ON SCHEMA '${pgSchema}' TO postgres;
GRANT ALL ON SCHEMA '${pgSchema}' TO public;`,
  )

  enums->Js.Array2.forEach((enumConfig: Internal.enumConfig) => {
    query :=
      query.contents ++
      `IF NOT EXISTS (
  SELECT 1 
  FROM pg_type 
  WHERE typname = '${enumConfig.name->Js.String2.toLowerCase}' 
  AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = '${pgSchema}')
) THEN CREATE TYPE "${pgSchema}".${enumConfig.name} AS ENUM(${enumConfig.variants->Js.Array2.joinWith(
          ", ",
        )});`
  })

  `DO $$ BEGIN ${query.contents} END $$;`
}

let make = (~sql: Postgres.sql, ~pgSchema): Persistence.storage => {
  let isInitialized = async () => {
    let schemas =
      await sql->Postgres.unsafe(
        `SELECT schema_name FROM information_schema.schemata WHERE schema_name = '${pgSchema}';`,
      )
    let schemaExists = schemas->Array.length > 0
    !schemaExists
  }

  let initialize = async (~entities, ~enums) => {
    let _ = await sql->Postgres.unsafe(makeInitializeQuery(~pgSchema, ~entities, ~enums))
  }

  {
    isInitialized,
    initialize,
  }
}
