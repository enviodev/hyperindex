open Belt
open Vitest

let simulateItem = Indexer.makeSimulateItem(OnEvent({event: Gravatar(EmptyEvent)}))

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
  let simulateItemAtBlock101 = Indexer.makeSimulateItem(
    OnEvent({event: Gravatar(EmptyEvent), block: {number: 101}}),
  )
  let _ = await indexer.process({
    chains: {
      \"1337": {
        simulate: [simulateItemAtBlock101],
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

// Test: simulate item with explicit block number → endBlock defaults to that block number
Async.it("Optional block params: endBlock defaults to max simulate block number", async t => {
  let indexer = Indexer.createTestIndexer()

  let simulateItemAtBlock50 = Indexer.makeSimulateItem(
    OnEvent({event: Gravatar(EmptyEvent), block: {number: 50}}),
  )
  let _ = await indexer.process({
    chains: {
      \"1337": {
        simulate: [simulateItemAtBlock50],
      },
    },
  })

  let entities = await (indexer.\"SimulateTestEvent").getAll()
  t.expect(entities).toEqual([{id: "50_0", blockNumber: 50, logIndex: 0, timestamp: 0}])
})

// Test: Fuel-style block height field is recognized for endBlock default
Async.it("Optional block params: endBlock defaults to max simulate block height (Fuel)", async t => {
  // getSimulateEndBlock uses config.ecosystem.blockNumberName to read the field.
  // For EVM it's "number", for Fuel it's "height". This test verifies the "height"
  // field path works by testing the function directly.
  let config = Indexer.Generated.makeGeneratedConfig()
  let result = TestIndexer.getSimulateEndBlock(
    ~simulateItems=[
      {"block": {"height": 50}}->(Utils.magic: 'a => Js.Json.t),
    ],
    ~config={...config, ecosystem: {...config.ecosystem, blockNumberName: "height"}},
    ~startBlock=1,
  )
  t.expect(result).toEqual(50)
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

// Test: schema rejects invalid types
Async.it("Optional block params: raises error for invalid startBlock type", async t => {
  let indexer = Indexer.createTestIndexer()

  let error = try {
    let _ = await indexer.process(
      {
        "chains": {
          "1337": {
            "startBlock": "not_a_number",
          },
        },
      }->(Utils.magic: 'a => Indexer.testIndexerProcessConfig),
    )
    None
  } catch {
  | Js.Exn.Error(err) => err->Js.Exn.message
  }

  t.expect(
    error->Option.map(msg => msg->Js.String2.startsWith("Invalid processConfig:")),
  ).toEqual(Some(true))
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
