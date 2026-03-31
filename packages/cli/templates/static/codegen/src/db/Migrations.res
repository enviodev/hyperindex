let resetStorage = async () => {
  Logging.trace("Resetting storage")
  await Indexer.Generated.codegenPersistence.storage.reset()
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
  let config = Indexer.Generated.configWithoutRegistrations
  let exitCode = try {
    await Indexer.Generated.codegenPersistence->Persistence.init(
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
  await resetStorage()->Promise.catch(err => {
    exitCode := Failure
    err
    ->ErrorHandling.make(~msg="Error dropping entity tables")
    ->ErrorHandling.log
    Promise.resolve()
  })
  if shouldExit {
    process->exit(exitCode.contents)
  }
  exitCode.contents
}
