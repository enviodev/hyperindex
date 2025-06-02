let sql = Db.sql
let unsafe = Postgres.unsafe

let internalMakeCreateTableSqlUnsafe = (table: Table.table) => {
  open Belt
  let fieldsMapped =
    table
    ->Table.getFields
    ->Array.map(field => {
      let {fieldType, isNullable, isArray, defaultValue} = field
      let fieldName = field->Table.getDbFieldName

      {
        `"${fieldName}" ${switch fieldType {
          | Custom(name) if !(name->Js.String2.startsWith("NUMERIC(")) =>
            `"${Env.Db.publicSchema}".${name}`
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

  `CREATE TABLE IF NOT EXISTS "${Env.Db.publicSchema}"."${table.tableName}"(${fieldsMapped}${primaryKeyFieldNames->Array.length > 0
      ? `, PRIMARY KEY(${primaryKey})`
      : ""});`
}

let creatTableIfNotExists = (sql, table) => {
  let query = table->internalMakeCreateTableSqlUnsafe
  sql->unsafe(query)
}

let makeCreateIndexQuery = (~tableName, ~indexFields) => {
  let indexName = tableName ++ "_" ++ indexFields->Js.Array2.joinWith("_")
  let index = indexFields->Belt.Array.map(idx => `"${idx}"`)->Js.Array2.joinWith(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON "${Env.Db.publicSchema}"."${tableName}"(${index}); `
}

let createTableIndices = (sql, table: Table.table) => {
  open Belt
  let tableName = table.tableName
  let createIndex = indexField => makeCreateIndexQuery(~tableName, ~indexFields=[indexField])
  let createCompositeIndex = indexFields => {
    makeCreateIndexQuery(~tableName, ~indexFields)
  }

  let singleIndices = table->Table.getSingleIndices
  let compositeIndices = table->Table.getCompositeIndices

  let query =
    singleIndices->Array.map(createIndex)->Js.Array2.joinWith("\n") ++
      compositeIndices->Array.map(createCompositeIndex)->Js.Array2.joinWith("\n")

  sql->unsafe(query)
}

let createDerivedFromDbIndex = (~derivedFromField: Table.derivedFromField, ~schema: Schema.t) => {
  let indexField = schema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn
  let query = makeCreateIndexQuery(
    ~tableName=derivedFromField.derivedFromEntity,
    ~indexFields=[indexField],
  )
  sql->unsafe(query)
}

let createEnumIfNotExists = (sql, enum: Enum.enum<_>) => {
  open Belt
  let {variants, name} = enum
  let mappedVariants = variants->Array.map(v => `'${v->Utils.magic}'`)->Js.Array2.joinWith(", ")
  let query = `DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 
    FROM pg_type 
    WHERE typname = '${name->Js.String2.toLowerCase}' 
    AND typnamespace = (SELECT oid FROM pg_namespace WHERE nspname = '${Env.Db.publicSchema}')
  ) THEN CREATE TYPE "${Env.Db.publicSchema}".${name} AS ENUM(${mappedVariants});
  END IF;
END $$;`

  sql->unsafe(query)
}

let deleteAllTables: unit => promise<unit> = async () => {
  Logging.trace("Dropping all tables")
  let query = `
    DO $$ 
    BEGIN
      DROP SCHEMA IF EXISTS ${Env.Db.publicSchema} CASCADE;
      CREATE SCHEMA ${Env.Db.publicSchema};
      GRANT ALL ON SCHEMA ${Env.Db.publicSchema} TO ${Env.Db.user};
      GRANT ALL ON SCHEMA ${Env.Db.publicSchema} TO public;
    END $$;`

  await sql->unsafe(query)
}

type t
@module external process: t = "process"

type exitCode = | @as(0) Success | @as(1) Failure
@send external exit: (t, exitCode) => unit = "exit"

let awaitEach = Utils.Array.awaitEach

// TODO: all the migration steps should run as a single transaction
let runUpMigrations = async (
  ~shouldExit,
  // Reset is used for db-setup
  ~reset=false,
) => {
  let exitCode = try {
    await Config.codegenPersistence->Persistence.init(~skipIsInitializedCheck=true, ~reset)
    Success
  } catch {
  | _ => Failure
  }
  if shouldExit {
    process->exit(exitCode)
  }
  exitCode
}

let runDownMigrations = async (~shouldExit) => {
  let exitCode = ref(Success)
  await deleteAllTables()->Promise.catch(err => {
    exitCode := Failure
    err
    ->ErrorHandling.make(~msg="EE804: Error dropping entity tables")
    ->ErrorHandling.log
    Promise.resolve()
  })
  if shouldExit {
    process->exit(exitCode.contents)
  }
  exitCode.contents
}
