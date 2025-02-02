let sql = Db.sql
let unsafe = Postgres.unsafe

let creatTableIfNotExists = (sql, table) => {
  open Belt
  let fieldsMapped =
    table
    ->Table.getFields
    ->Array.map(field => {
      let {fieldType, isNullable, isArray, defaultValue} = field
      let fieldName = field->Table.getDbFieldName

      {
        `"${fieldName}" ${(fieldType :> string)}${isArray ? "[]" : ""}${switch defaultValue {
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

  let query = `
    CREATE TABLE IF NOT EXISTS ${Env.Db.publicSchema}."${table.tableName}"(${fieldsMapped}${primaryKeyFieldNames->Array.length > 0
      ? `, PRIMARY KEY(${primaryKey})`
      : ""});`

  sql->unsafe(query)
}

let makeCreateIndexQuery = (~tableName, ~indexFields) => {
  let indexName = tableName ++ "_" ++ indexFields->Js.Array2.joinWith("_")
  let index = indexFields->Belt.Array.map(idx => `"${idx}"`)->Js.Array2.joinWith(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON ${Env.Db.publicSchema}."${tableName}"(${index}); `
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
  let query = `
      DO $$ BEGIN
      IF NOT EXISTS(SELECT 1 FROM pg_type WHERE typname = '${name->Js.String2.toLowerCase}') THEN
        CREATE TYPE ${name} AS ENUM(${mappedVariants});
        END IF;
      END $$; `

  sql->unsafe(query)
}

let deleteAllTables: unit => promise<unit> = async () => {
  Logging.trace("Dropping all tables")
  // NOTE: we can refine the `IF EXISTS` part because this now prints to the terminal if the table doesn't exist (which isn't nice for the developer).

  @warning("-21")
  await (
    %raw(
      "sql.unsafe`DROP SCHEMA public CASCADE;CREATE SCHEMA public;GRANT ALL ON SCHEMA public TO postgres;GRANT ALL ON SCHEMA public TO public;`"
    )
  )
}

type t
@module external process: t = "process"

type exitCode = | @as(0) Success | @as(1) Failure
@send external exit: (t, exitCode) => unit = "exit"

let awaitEach = Utils.Array.awaitEach

// TODO: all the migration steps should run as a single transaction
let runUpMigrations = async (~shouldExit) => {
  let exitCode = ref(Success)
  let logger = Logging.createChild(~params={"context": "Running DB Migrations"})

  let handleFailure = async (res, ~msg) =>
    switch await res {
    | exception exn =>
      exitCode := Failure
      exn->ErrorHandling.make(~msg, ~logger)->ErrorHandling.log
    | _ => ()
    }

  //Add all enums
  await Enums.allEnums->awaitEach(enum => {
    let module(EnumMod) = enum
    createEnumIfNotExists(Db.sql, EnumMod.enum)->handleFailure(
      ~msg=`EE800: Error creating ${EnumMod.enum.name} enum`,
    )
  })

  //Create all tables with indices
  await [Db.allStaticTables, Db.allEntityTables, Db.allEntityHistoryTables]
  ->Belt.Array.concatMany
  ->awaitEach(async table => {
    await creatTableIfNotExists(Db.sql, table)->handleFailure(
      ~msg=`EE800: Error creating ${table.tableName} table`,
    )
    await createTableIndices(Db.sql, table)->handleFailure(
      ~msg=`EE800: Error creating ${table.tableName} indices`,
    )
  })

  await Db.allEntityHistory->awaitEach(async entityHistory => {
    await sql
    ->Postgres.unsafe(entityHistory.createInsertFnQuery)
    ->handleFailure(~msg=`EE800: Error creating ${entityHistory.table.tableName} insert function`)
  })

  //Create all derivedFromField indices (must be done after all tables are created)
  await Db.allEntityTables
  ->awaitEach(async table => {
    await table
    ->Table.getDerivedFromFields
    ->awaitEach(derivedFromField => {
      createDerivedFromDbIndex(~derivedFromField, ~schema=Db.schema)->handleFailure(
        ~msg=`Error creating derivedFrom index of "${derivedFromField.fieldName}" in entity "${table.tableName}"`,
      )
    })
  })

  await TrackTables.trackAllTables()->Promise.catch(err => {
    Logging.errorWithExn(err, `EE803: Error tracking tables`)->Promise.resolve
  })

  if shouldExit {
    process->exit(exitCode.contents)
  }
  exitCode.contents
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

let setupDb = async () => {
  Logging.info("Provisioning Database")
  // TODO: we should make a hash of the schema file (that gets stored in the DB) and either drop the tables and create new ones or keep this migration.
  //       for now we always run the down migration.
  // if (process.env.MIGRATE === "force" || hash_of_schema_file !== hash_of_current_schema)
  let exitCodeDown = await runDownMigrations(~shouldExit=false)
  // else
  //   await clearDb()

  let exitCodeUp = await runUpMigrations(~shouldExit=false)

  let exitCode = switch (exitCodeDown, exitCodeUp) {
  | (Success, Success) => Success
  | _ => Failure
  }

  process->exit(exitCode)
}
