open Vitest

// Reorg detection now lives in the Rust BlockStore: merging a page compares
// block hashes and reports the lowest in-threshold mismatch; pruning keeps
// in-threshold hashes; rollback reads find the last valid block.
describe("Block store reorg detection", () => {
  let scannedHashesFixture = [(1, "0x123"), (50, "0x456"), (300, "0x789"), (500, "0x5432")]

  let makePage = entries =>
    BlockStore.fromJs(
      entries->Array.map(((blockNumber, blockHash)): BlockStore.inputBlock => {
        blockNumber,
        blockHash,
      }),
      ~ecosystem=Svm, // SVM stores hashes as raw strings, so short mock hashes work
      ~shouldChecksum=false,
    )

  let mock = entries => {
    let store = BlockStore.make(~ecosystem=Svm, ~shouldChecksum=false)
    switch store->BlockStore.merge(makePage(entries), ~fromBlock=0, ~reportOnly=false) {
    | Null.Value(_) => JsError.throwWithMessage("Unexpected reorg detected in mock setup")
    | Null.Null => ()
    }
    store
  }

  let mergeNoReorg = (store, entries, ~fromBlock) => {
    switch store->BlockStore.merge(makePage(entries), ~fromBlock, ~reportOnly=false) {
    | Null.Value(_) => JsError.throwWithMessage("Unexpected reorg detected")
    | Null.Null => store
    }
  }

  it("getHashedBlockNumbers applies the reorg threshold at read time", t => {
    let store = mock(scannedHashesFixture)
    t.expect(
      store->BlockStore.getHashedBlockNumbers(~fromBlock=500 - 200, ~belowBlock=501),
      ~message="Both 300 and 500 should be included in the threshold and below 501",
    ).toEqual([300, 500])
    t.expect(
      store->BlockStore.getHashedBlockNumbers(~fromBlock=501 - 200, ~belowBlock=501),
      ~message="If chain progresses one more block, 300 is not included in the threshold anymore",
    ).toEqual([500])
    t.expect(
      store->BlockStore.getHashedBlockNumbers(~fromBlock=499 - 200, ~belowBlock=500),
      ~message="Returns blocks below 500 that are in threshold",
    ).toEqual([300])
    t.expect(
      mock([(300, "0x789"), (50, "0x456"), (500, "0x5432"), (1, "0x123")])->BlockStore.getHashedBlockNumbers(
        ~fromBlock=500 - 200,
        ~belowBlock=501,
      ),
      ~message="The order of merged blocks doesn't matter",
    ).toEqual([300, 500])
    t.expect(
      store->BlockStore.getHashedBlockNumbers(~fromBlock=500 - 450, ~belowBlock=501),
      ~message="A wider threshold includes more blocks",
    ).toEqual([50, 300, 500])
  })

  it("Merging pages accumulates scanned hashes", t => {
    let store = mock([])
    let store =
      store
      ->mergeNoReorg([(1, "0x123")], ~fromBlock=0)
      ->mergeNoReorg([(1, "0x123"), (50, "0x456")], ~fromBlock=0)
      ->mergeNoReorg([(50, "0x456"), (300, "0x789")], ~fromBlock=0)
      ->mergeNoReorg([(300, "0x789"), (500, "0x5432")], ~fromBlock=0)

    t.expect({
      "blockNumbers": store->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=501),
      "hash300": store->BlockStore.getHash(300),
    }).toEqual({
      "blockNumbers": [1, 50, 300, 500],
      "hash300": Null.Value("0x789"),
    })
  })

  it("Mismatches below the merge threshold are not compared", t => {
    let store = mock(scannedHashesFixture)
    // 50 conflicts but is below fromBlock (the reorg threshold), so the merge
    // applies without detection and the hash converges to the received one.
    let store = store->mergeNoReorg([(50, "0x50-different"), (400, "0x400")], ~fromBlock=300)
    t.expect(store->BlockStore.getHash(50)).toEqual(Null.Value("0x50-different"))
  })

  it("Detects a reorg when a received hash doesn't match the scanned block", t => {
    let reorgDetected: BlockStore.hashMismatch = {
      blockNumber: 10,
      storedHash: "0x10-invalid",
      receivedHash: "0x10",
    }

    t.expect(
      mock([(10, "0x10-invalid")])->BlockStore.merge(
        makePage([(10, "0x10")]),
        ~fromBlock=0,
        ~reportOnly=false,
      ),
    ).toEqual(Null.Value(reorgDetected))

    // Rollback mode discards the page: the stored hash stays, so the same
    // mismatch re-reports until the store is rolled back.
    let store = mock([(10, "0x10-invalid")])
    let _ = store->BlockStore.merge(makePage([(10, "0x10")]), ~fromBlock=0, ~reportOnly=false)
    t.expect(
      store->BlockStore.getHash(10),
      ~message="Rollback mode keeps the scanned hash for the rollback comparison",
    ).toEqual(Null.Value("0x10-invalid"))

    // Detect-only mode reports but still merges, so the next page with the
    // same hash no longer reports.
    let store = mock([(10, "0x10-invalid")])
    t.expect(
      store->BlockStore.merge(makePage([(10, "0x10")]), ~fromBlock=0, ~reportOnly=true),
    ).toEqual(Null.Value(reorgDetected))
    t.expect(store->BlockStore.getHash(10)).toEqual(Null.Value("0x10"))
    t.expect(
      store->BlockStore.merge(makePage([(10, "0x10")]), ~fromBlock=0, ~reportOnly=true),
      ~message="After the overwrite the same page merges cleanly",
    ).toEqual(Null.Null)
  })

  it("Reports the lowest mismatching block of a page", t => {
    t.expect(
      mock([(10, "0x10"), (11, "0x11"), (12, "0x12")])->BlockStore.merge(
        makePage([(12, "0x12-different"), (11, "0x11-different")]),
        ~fromBlock=0,
        ~reportOnly=false,
      ),
    ).toEqual(
      Null.Value({
        BlockStore.blockNumber: 11,
        storedHash: "0x11",
        receivedHash: "0x11-different",
      }),
    )
  })

  it("Detects a reorg when a page contains the same block number with different hashes", t => {
    t.expect(
      mock([])->BlockStore.merge(
        makePage([(10, "0x10"), (10, "0x10-different")]),
        ~fromBlock=0,
        ~reportOnly=false,
      ),
      ~message="The second observation of block 10 collides with the first one inside the same page",
    ).toEqual(
      Null.Value({
        BlockStore.blockNumber: 10,
        storedHash: "0x10",
        receivedHash: "0x10-different",
      }),
    )

    t.expect(
      mock([])->BlockStore.merge(
        makePage([(10, "0x10"), (10, "0x10")]),
        ~fromBlock=0,
        ~reportOnly=false,
      ),
      ~message="Duplicate block numbers with the same hash are accepted",
    ).toEqual(Null.Null)
  })

  it("rollback drops hashes above the valid block", t => {
    let store = mock(scannedHashesFixture)
    store->BlockStore.rollback(499, ~keepHashes=false)
    t.expect(store->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=1000)).toEqual([
      1,
      50,
      300,
    ])
  })

  it("prune keeps in-threshold hashes as hash-only rows", t => {
    let store = mock(scannedHashesFixture)
    store->BlockStore.prune(500, ~keepHashesFrom=300)
    t.expect({
      "blockNumbers": store->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=1000),
      "prunedHash": store->BlockStore.getHash(50),
      "keptHash": store->BlockStore.getHash(300),
    }).toEqual({
      "blockNumbers": [300, 500],
      "prunedHash": Null.Null,
      "keptHash": Null.Value("0x789"),
    })
  })

  it("Correctly finds the latest valid scanned block", t => {
    let store = mock(scannedHashesFixture)
    let latestValid = pairs =>
      store->BlockStore.latestValidBlock(
        ~blockNumbers=pairs->Array.map(((n, _)) => n),
        ~hashes=pairs->Array.map(((_, h)) => h),
      )

    t.expect(
      latestValid([(1, "0x123"), (50, "0x456"), (300, "0x789differnt"), (500, "0x5432differnt")]),
      ~message="Should return the latest matching block before the first mismatch",
    ).toEqual(Null.Value(50))
    t.expect(
      latestValid([(300, "0x789differnt"), (500, "0x5432differnt")]),
      ~message="Returns null if there's no valid block among the pairs",
    ).toEqual(Null.Null)
    t.expect(
      latestValid([(1, "0x123"), (50, "0x456"), (300, "0x789differnt"), (500, "0x5432")]),
      ~message="Stops at a mismatch even when a higher block matches again",
    ).toEqual(Null.Value(50))
    t.expect(
      latestValid([(500, "0x5432-different")]),
      ~message="Returns null if the different block is the only one checked",
    ).toEqual(Null.Null)
    t.expect(
      latestValid([(1, "0x123"), (99, "0x99")]),
      ~message="A block the store no longer holds counts as a mismatch",
    ).toEqual(Null.Value(1))
  })
})
