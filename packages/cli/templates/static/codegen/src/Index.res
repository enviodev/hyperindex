// Crash on unhandled promise rejections with a readable error.
// ReScript exceptions compile to plain objects, not Error instances, so Node.js prints "#<Object>".
NodeJs.globalProcess->NodeJs.onUnhandledRejection(reason => {
  Logging.errorWithExn(reason->Utils.prettifyExn, "Unhandled promise rejection")
  NodeJs.process->NodeJs.exitWithCode(Failure)
})

let main = async () => {
  try {
    await Main.start(
      ~makeGeneratedConfig=Indexer.Generated.makeGeneratedConfig,
    )
  } catch {
  | e => {
      e->ErrorHandling.make(~msg="Failed at initialization")->ErrorHandling.log
      NodeJs.process->NodeJs.exitWithCode(Failure)
    }
  }
}

// Export the Promise so callers (bin.mjs start-indexer) can await it.
// When run directly via `node Index.res.mjs`, the Promise keeps the
// process alive until the indexer finishes or crashes.
let promise = main()
