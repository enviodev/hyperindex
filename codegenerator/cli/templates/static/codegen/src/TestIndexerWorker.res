// Worker entry point for test indexer
// This file runs in a worker thread when createTestIndexer().process() is called

let config = Indexer.Generated.configWithoutRegistrations

TestIndexer.initTestWorker(
  ~makeGeneratedConfig=Indexer.Generated.makeGeneratedConfig,
  ~makePersistence=(~storage) =>
    Persistence.make(
      ~userEntities=config.userEntities,
      ~allEnums=config.allEnums,
      ~storage,
    ),
)
