open Vitest

let simulateItem = {
  "contract": "Gravatar",
  "event": "CustomSelection",
  "transaction": {"from": "0xfoo"},
  "block": {"parentHash": "0xParentHash"},
}

// Test: simulate with no startBlock/endBlock → defaults from config
Async.it("Optional block params: defaults startBlock from config and endBlock to startBlock with simulate", async t => {
  let indexer = Indexer.createTestIndexer()

  let result = await indexer.process(
    {
      "chains": {
        "1337": {
          "simulate": [simulateItem],
        },
      },
    }->Utils.magic,
  )
  t.expect(result.changes->Array.length).toEqual(1)
})

// Test: simulate with only startBlock → endBlock defaults to startBlock
Async.it("Optional block params: defaults endBlock to startBlock when only startBlock is provided", async t => {
  let indexer = Indexer.createTestIndexer()

  let result = await indexer.process(
    {
      "chains": {
        "1337": {
          "startBlock": 5,
          "simulate": [simulateItem],
        },
      },
    }->Utils.magic,
  )
  t.expect(result.changes->Array.length).toEqual(1)
})

// Test: explicit startBlock and endBlock still work
Async.it("Optional block params: uses explicit startBlock and endBlock when provided", async t => {
  let indexer = Indexer.createTestIndexer()

  let result = await indexer.process(
    {
      "chains": {
        "1337": {
          "startBlock": 1,
          "endBlock": 100,
          "simulate": [simulateItem],
        },
      },
    }->Utils.magic,
  )
  t.expect(result.changes->Array.length).toEqual(1)
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
      }->Utils.magic,
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
      }->Utils.magic,
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
    let _ = await indexer.process(
      {
        "chains": {
          "1337": {
            "startBlock": 1,
          },
        },
      }->Utils.magic,
    )
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
