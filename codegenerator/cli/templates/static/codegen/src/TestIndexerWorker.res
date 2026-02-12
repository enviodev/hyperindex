// Worker entry point for test indexer
// This file runs in a worker thread when createTestIndexer().process() is called

let config = Generated.configWithoutRegistrations

TestIndexer.initTestWorker(
  ~makeGeneratedConfig=Generated.makeGeneratedConfig,
  ~makePersistence=(~storage) =>
    Persistence.make(
      ~userEntities=config.userEntities,
      ~allEnums=config.allEnums,
      ~storage,
    ),
)
