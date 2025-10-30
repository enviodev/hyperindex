let unsafe = Postgres.unsafe

let deleteAllTables: unit => promise<unit> = async () => {
  Logging.trace("Dropping all tables")
  let query = `
    DO $$ 
    BEGIN
      DROP SCHEMA IF EXISTS ${Env.Db.publicSchema} CASCADE;
      CREATE SCHEMA ${Env.Db.publicSchema};
      GRANT ALL ON SCHEMA ${Env.Db.publicSchema} TO "${Env.Db.user}";
      GRANT ALL ON SCHEMA ${Env.Db.publicSchema} TO public;
    END $$;`

  await Generated.codegenPersistence.sql->unsafe(query)
}

type t
@module external process: t = "process"

type exitCode = | @as(0) Success | @as(1) Failure
@send external exit: (t, exitCode) => unit = "exit"

let runUpMigrations = async (
  ~shouldExit,
  // Reset is used for db-setup
  ~reset=false,
) => {
  let config = Generated.configWithoutRegistrations
  let exitCode = try {
    await Generated.codegenPersistence->Persistence.init(
      ~reset,
      ~chainConfigs=config.chainMap->ChainMap.values,
    )
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
