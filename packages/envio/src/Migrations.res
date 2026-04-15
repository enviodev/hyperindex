type t
@module external process: t = "process"

type exitCode = | @as(0) Success | @as(1) Failure
@send external exit: (t, exitCode) => unit = "exit"

let runUpMigrations = async (
  ~shouldExit,
  // Reset is used for db-setup
  ~reset=false,
) => {
  let config = Config.fromConfigView()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  let exitCode = try {
    await persistence->Persistence.init(~reset, ~chainConfigs=config.chainMap->ChainMap.values)
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
  let config = Config.fromConfigView()
  let persistence = PgStorage.makePersistenceFromConfig(~config)
  let exitCode = try {
    await persistence.storage.reset()
    Success
  } catch {
  | err =>
    err
    ->ErrorHandling.make(~msg="Error dropping entity tables")
    ->ErrorHandling.log
    Failure
  }
  if shouldExit {
    process->exit(exitCode)
  }
  exitCode
}
