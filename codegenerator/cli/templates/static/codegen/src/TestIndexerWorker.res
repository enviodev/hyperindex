// Worker entry point for test indexer
// This file runs in a worker thread when createTestIndexer().process() is called

TestIndexer.initTestWorker(
  ~makeGeneratedConfig=Generated.makeGeneratedConfig,
  ~makePersistence=(~storage) =>
    Persistence.make(
      ~userEntities=Indexer.Entities.userEntities,
      ~allEnums=Indexer.Enums.allEnums,
      ~storage,
    ),
)
