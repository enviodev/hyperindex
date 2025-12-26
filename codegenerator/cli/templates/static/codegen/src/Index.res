let main = async () => {
  try {
    await Main.start(
      ~registerAllHandlers=Generated.registerAllHandlers,
      ~makeGeneratedConfig=Generated.makeGeneratedConfig,
      ~persistence=Generated.codegenPersistence,
    )
  } catch {
  | e => {
      e->ErrorHandling.make(~msg="Failed at initialization")->ErrorHandling.log
      NodeJs.process->NodeJs.exitWithCode(Failure)
    }
  }
}

main()->ignore
