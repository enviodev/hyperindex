open JestBench

benchmarkSuite(
  "benchmark E2E demo",
  {
    "3 newgravatar & 3 updategravatar": defer => {
      EventProcessing.processEventBatch(MockEvents.eventBatch, ~context=Context.getContext())
      ->Js.Promise2.then(_ => defer.resolve(.)->Js.Promise2.resolve)
      ->ignore
    },
  },
)
