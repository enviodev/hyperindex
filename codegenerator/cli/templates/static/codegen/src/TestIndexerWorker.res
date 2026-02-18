// Worker entry point for test indexer
// This file runs in a worker thread when createTestIndexer().process() is called

TestIndexer.initTestWorker(
  ~makeGeneratedConfig=Indexer.Generated.makeGeneratedConfig,
)
