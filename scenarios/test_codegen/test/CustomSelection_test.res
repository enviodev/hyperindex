open Vitest

Async.it("Handles event with a custom field selection (in ReScript)", async _t => {
  let indexer = Indexer.createTestIndexer()

  // Process an EmptyEvent (no schema assertions in its handler)
  // Custom field selection is verified at compile time via the type system
  let processConfig: Indexer.testIndexerProcessConfig = {
    "chains": {
      "1337": {
        "startBlock": 1,
        "endBlock": 100,
        "simulate": [
          {
            "contract": "Gravatar",
            "event": "EmptyEvent",
          },
        ],
      },
    },
  }->Utils.magic
  let _ = await indexer.process(processConfig)
})
