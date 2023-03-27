open JestBench

benchmarkSuite(
  "test benchmark 1",
  {
    "log test": () => Js.log("benchmark success"),
  },
)
