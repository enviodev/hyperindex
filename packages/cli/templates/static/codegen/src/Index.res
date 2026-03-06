// Catch unhandled promise rejections to display full error details instead of the opaque "#<Object>" message.
// ReScript exceptions compile to plain objects, not Error instances, so Node.js can't display them.
// With --unhandled-rejections=throw (Node v15+ default), registering this handler prevents Node from
// crashing on unhandled rejections, so the handler must not re-throw or exit.
NodeJs.process->NodeJs.onUnhandledRejection(reason => {
  try {
    Js.Console.error("Unhandled promise rejection:")
    Js.Console.error(reason->Utils.prettifyExn)
  } catch {
  | _ => Js.Console.error2("Unhandled promise rejection (raw):", reason)
  }
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
