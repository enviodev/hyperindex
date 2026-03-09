// Crash on unhandled promise rejections with a readable error.
// ReScript exceptions compile to plain objects, not Error instances, so Node.js prints "#<Object>".
NodeJs.globalProcess->NodeJs.onUnhandledRejection(reason => {
  try {
    Js.Console.error("Unhandled promise rejection:")
    Js.Console.error(reason->Utils.prettifyExn)
  } catch {
  | _ => Js.Console.error2("Unhandled promise rejection (raw):", reason)
  }
  NodeJs.process->NodeJs.exitWithCode(Failure)
})

let main = async () => {
  try {
    await Main.start(
      ~makeGeneratedConfig=Indexer.Generated.makeGeneratedConfig,
      ~persistence=Indexer.Generated.codegenPersistence,
    )
  } catch {
  | e => {
      e->ErrorHandling.make(~msg="Failed at initialization")->ErrorHandling.log
      NodeJs.process->NodeJs.exitWithCode(Failure)
    }
  }
}

main()->ignore
