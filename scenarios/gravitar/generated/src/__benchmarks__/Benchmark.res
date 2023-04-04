open JestBench

benchmarkSuite(
  "benchmark E2E demo",
  {
    "3 newGravitar & 3 updateGravitar": defer => {
      EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
      ->Js.Promise2.then(_ => defer.resolve(.)->Js.Promise2.resolve)
      ->ignore
    },
  },
)
