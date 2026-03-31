let runUpMigrations = async (~persistence, ~config: Config.t, ~shouldExit, ~reset=false) => {
  let exitCode: NodeJs.exitCode = try {
    await persistence->Persistence.init(~reset, ~chainConfigs=config.chainMap->ChainMap.values)
    NodeJs.Success
  } catch {
  | _ => Failure
  }
  if shouldExit {
    NodeJs.process->NodeJs.exitWithCode(exitCode)
  }
  exitCode
}

let runDownMigrations = async (~persistence: Persistence.t, ~shouldExit) => {
  let exitCode = ref((NodeJs.Success: NodeJs.exitCode))
  await persistence.storage.reset()->Promise.catch(err => {
    exitCode := Failure
    err->ErrorHandling.make(~msg="Error dropping entity tables")->ErrorHandling.log
    Promise.resolve()
  })
  if shouldExit {
    NodeJs.process->NodeJs.exitWithCode(exitCode.contents)
  }
  exitCode.contents
}
