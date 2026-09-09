// Top-of-graph module — putting these in Main or TestIndexer would cycle
// back through Envio.

let indexer: unknown = Main.getGlobalIndexer()

let createTestIndexer: unit => unknown = () => {
  TestIndexer.createTestIndexer()->(Utils.magic: TestIndexer.t<'a> => unknown)
}
