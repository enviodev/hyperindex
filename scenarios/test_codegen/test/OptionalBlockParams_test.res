open Belt
open Vitest

let simulateItem: Envio.evmSimulateEventItem = {
  contract: "Gravatar",
  event: "EmptyEvent",
}

// Test: simulate with no startBlock/endBlock → defaults from config
Async.it("Optional block params: defaults startBlock from config and endBlock to startBlock with simulate", async t => {
  let indexer = Indexer.createTestIndexer()

  // config.yaml has start_block: 1 for chain 1337
  let _ = await indexer.process({
    chains: {
      \"1337": {simulate: [simulateItem]},
    },
  })

  let entities = await (indexer.\"SimulateTestEvent").getAll()
  // startBlock defaults to config (1), endBlock defaults to startBlock (1)
  t.expect(entities).toEqual([{id: "1_0", blockNumber: 1, logIndex: 0, timestamp: 0}])
})

// Test: simulate with only startBlock → endBlock defaults to startBlock
Async.it("Optional block params: defaults endBlock to startBlock when only startBlock is provided", async t => {
  let indexer = Indexer.createTestIndexer()

  let _ = await indexer.process({
    chains: {
      \"1337": {startBlock: 5, simulate: [simulateItem]},
    },
  })

  let entities = await (indexer.\"SimulateTestEvent").getAll()
  // Event block defaults to config startBlock (1) in SimulateItems.parse,
  // but the process range is startBlock=5, endBlock=5
  t.expect(entities).toEqual([{id: "1_0", blockNumber: 1, logIndex: 0, timestamp: 0}])
})

// Test: explicit startBlock and endBlock still work
Async.it("Optional block params: uses explicit startBlock and endBlock when provided", async t => {
  let indexer = Indexer.createTestIndexer()

  let _ = await indexer.process({
    chains: {
      \"1337": {startBlock: 1, endBlock: 100, simulate: [simulateItem]},
    },
  })

  let entities = await (indexer.\"SimulateTestEvent").getAll()
  t.expect(entities).toEqual([{id: "1_0", blockNumber: 1, logIndex: 0, timestamp: 0}])
})

// Test: startBlock defaults to progressBlock+1 after a prior process() call
Async.it("Optional block params: startBlock defaults to progressBlock+1 on second process call", async t => {
  let indexer = Indexer.createTestIndexer()

  // First process: blocks 1-100
  let _ = await indexer.process({
    chains: {
      \"1337": {startBlock: 1, endBlock: 100, simulate: [simulateItem]},
    },
  })

  // Second process: omit startBlock → should default to 101 (progressBlock+1)
  // Use explicit block number so the event falls within the resolved range [101, 101]
  let _ = await indexer.process({
    chains: {
      \"1337": {
        simulate: [{...simulateItem, block: %raw(`{number: 101}`)}],
      },
    },
  })

  let entities = await (indexer.\"SimulateTestEvent").getAll()
  let entities = entities->SortArray.stableSortBy((a, b) => compare(a.blockNumber, b.blockNumber))
  t.expect(entities).toEqual([
    {id: "1_0", blockNumber: 1, logIndex: 0, timestamp: 0},
    {id: "101_0", blockNumber: 101, logIndex: 0, timestamp: 0},
  ])
})

// Test: non-numeric chain ID → error
Async.it("Optional block params: raises error for non-numeric chain ID", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process(
      {
        "chains": {
          "abc": {
            "startBlock": 1,
            "endBlock": 100,
          },
        },
      }->(Utils.magic: 'a => Indexer.testIndexerProcessConfig),
    )
    None
  } catch {
  | Js.Exn.Error(err) => err->Js.Exn.message
  }

  t.expect(error).toEqual(
    Some("Invalid chain ID \"abc\": expected a numeric chain ID"),
  )
})

// Test: chain ID not in config → error
Async.it("Optional block params: raises error for chain ID not in config", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process(
      {
        "chains": {
          "9999": {
            "startBlock": 1,
            "endBlock": 100,
          },
        },
      }->(Utils.magic: 'a => Indexer.testIndexerProcessConfig),
    )
    None
  } catch {
  | Js.Exn.Error(err) => err->Js.Exn.message
  }

  t.expect(error).toEqual(
    Some("Chain 9999 is not configured in config.yaml"),
  )
})

// Test: no simulate, no endBlock → error
Async.it("Optional block params: raises error when endBlock is missing without simulate", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process({
      chains: {
        \"1337": {startBlock: 1},
      },
    })
    None
  } catch {
  | Js.Exn.Error(err) => err->Js.Exn.message
  }

  t.expect(error).toEqual(
    Some(
      "endBlock is required for chain 1337 when simulate is not provided",
    ),
  )
})
