// Catch unhandled promise rejections before they crash the process with an opaque "#<Object>" message.
// ReScript exceptions compile to plain objects, not Error instances, so Node.js can't display them.
NodeJs.process->NodeJs.onUnhandledRejection(reason => {
  let err = reason->ErrorHandling.make(~msg="Unhandled promise rejection")
  err->ErrorHandling.log
  raise(reason)
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
