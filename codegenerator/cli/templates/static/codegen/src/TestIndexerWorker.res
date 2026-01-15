// Worker entry point for test indexer
// This file runs in a worker thread when createTestIndexer().process() is called

TestIndexer.initTestWorker(
  ~registerAllHandlers=Generated.registerAllHandlers,
  ~makePersistence=(~storage) =>
    Persistence.make(
      ~userEntities=Entities.userEntities,
      ~allEnums=Enums.allEnums,
      ~storage,
    ),
)
