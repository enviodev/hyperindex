let make = (~inMemoryStore: InMemoryStore.t): Ports.MarkBatchProcessed.t =>
  () => {
    inMemoryStore.isProcessing = false
    inMemoryStore.processedBatchesCount = inMemoryStore.processedBatchesCount + 1
  }
