// Top-of-graph module — putting these in Main or TestIndexer would cycle
// back through Envio.

let indexer: unknown = Main.getGlobalIndexer()

let createTestIndexer: unit => unknown = () => {
  let workerPath =
    NodeJs.Path.join(
      NodeJs.Path.getDirname(NodeJs.ImportMeta.importMeta),
      "TestIndexerWorker.res.mjs",
    )->NodeJs.Path.toString
  TestIndexer.makeCreateTestIndexer(~config=Config.load(), ~workerPath)()->(
    Utils.magic: TestIndexer.t<'a> => unknown
  )
}
