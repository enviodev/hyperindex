open Vitest

describe("Chain buffer reorg detection", () => {
  let scannedHashesFixture = [(1, "0x123"), (50, "0x456"), (300, "0x789"), (500, "0x5432")]

  let makePage = entries =>
    BufferPage.fromBlocks(
      entries->Array.map(((blockNumber, blockHash)): BufferPage.observedBlock => {
        blockNumber,
        blockHash,
      }),
      ~ecosystem=Svm, // SVM stores hashes as raw strings, so short mock hashes work
    )

  let merge = (store, page, ~fromBlock, ~reportOnly) =>
    (store->ChainBuffer.mergePage(page, ~reorgThreshold=fromBlock, ~reportOnly)).mismatch

  let mock = entries => {
    let store = TestChainBuffer.decodedBuffer(~onEventRegistrations=[], ~ecosystem=Svm)
    switch store->merge(makePage(entries), ~fromBlock=0, ~reportOnly=false) {
    | Some(_) => JsError.throwWithMessage("Unexpected reorg detected in mock setup")
    | None => ()
    }
    store
  }

  let mergeNoReorg = (store, entries, ~fromBlock) => {
    switch store->merge(makePage(entries), ~fromBlock, ~reportOnly=false) {
    | Some(_) => JsError.throwWithMessage("Unexpected reorg detected")
    | None => store
    }
  }

  let hashedBlockNumbers = (store, ~fromBlock, ~belowBlock) =>
    (store->ChainBuffer.getBlockHashes(~fromBlock, ~belowBlock)).blockNumbers

  // What a rollback to `target` does to the chain's blocks.
  let rollback = (store, target) =>
    store->ChainBuffer.removeBlocksInBlockRange(
      ~fromBlock=target + 1,
      ~toBlock=Int.Constants.maxValue,
    )

  it("getHashedBlockNumbers applies the reorg threshold at read time", t => {
    let store = mock(scannedHashesFixture)
    t.expect(
      store->hashedBlockNumbers(~fromBlock=500 - 200, ~belowBlock=501),
      ~message="Both 300 and 500 should be included in the threshold and below 501",
    ).toEqual([300, 500])
    t.expect(
      store->hashedBlockNumbers(~fromBlock=501 - 200, ~belowBlock=501),
      ~message="If chain progresses one more block, 300 is not included in the threshold anymore",
    ).toEqual([500])
    t.expect(
      store->hashedBlockNumbers(~fromBlock=499 - 200, ~belowBlock=500),
      ~message="Returns blocks below 500 that are in threshold",
    ).toEqual([300])
    t.expect(
      mock([(300, "0x789"), (50, "0x456"), (500, "0x5432"), (1, "0x123")])->hashedBlockNumbers(
        ~fromBlock=500 - 200,
        ~belowBlock=501,
      ),
      ~message="The order of merged blocks doesn't matter",
    ).toEqual([300, 500])
    t.expect(
      store->hashedBlockNumbers(~fromBlock=500 - 450, ~belowBlock=501),
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
      "blockNumbers": store->hashedBlockNumbers(~fromBlock=0, ~belowBlock=501),
      "hash300": store->TestChainBuffer.blockHashAt(300),
    }).toEqual({
      "blockNumbers": [1, 50, 300, 500],
      "hash300": Null.Value("0x789"),
    })
  })

  it("Mismatches below the merge threshold are not compared", t => {
    let store = mock(scannedHashesFixture)
    // 50 conflicts but is below fromBlock (the reorg threshold), so the merge
    // applies without detection and the hash converges to the received one.
    // Nothing is dropped here - the store is trimmed on batch progress.
    let store = store->mergeNoReorg([(50, "0x50-different"), (400, "0x400")], ~fromBlock=300)
    t.expect({
      "below": store->TestChainBuffer.blockHashAt(50),
      "inThreshold": store->TestChainBuffer.blockHashAt(400),
    }).toEqual({
      "below": Null.Value("0x50-different"),
      "inThreshold": Null.Value("0x400"),
    })
  })

  it("Detects a reorg when a received hash doesn't match the scanned block", t => {
    let reorgDetected: BufferPage.hashMismatch = {
      blockNumber: 10,
      storedHash: "0x10-invalid",
      receivedHash: "0x10",
    }

    t.expect(
      mock([(10, "0x10-invalid")])->merge(
        makePage([(10, "0x10")]),
        ~fromBlock=0,
        ~reportOnly=false,
      ),
    ).toEqual(Some(reorgDetected))

    // Rollback mode discards the page: the stored hash stays, so the same
    // mismatch re-reports until the store is rolled back.
    let store = mock([(10, "0x10-invalid")])
    let _ = store->merge(makePage([(10, "0x10")]), ~fromBlock=0, ~reportOnly=false)
    t.expect(
      store->TestChainBuffer.blockHashAt(10),
      ~message="Rollback mode keeps the scanned hash for the rollback comparison",
    ).toEqual(Null.Value("0x10-invalid"))

    // Detect-only mode reports but still merges, so the next page with the
    // same hash no longer reports.
    let store = mock([(10, "0x10-invalid")])
    t.expect(store->merge(makePage([(10, "0x10")]), ~fromBlock=0, ~reportOnly=true)).toEqual(
      Some(reorgDetected),
    )
    t.expect(store->TestChainBuffer.blockHashAt(10)).toEqual(Null.Value("0x10"))
    t.expect(
      store->merge(makePage([(10, "0x10")]), ~fromBlock=0, ~reportOnly=true),
      ~message="After the overwrite the same page merges cleanly",
    ).toEqual(None)
  })

  it("Reports the lowest mismatching block of a page", t => {
    t.expect(
      mock([(10, "0x10"), (11, "0x11"), (12, "0x12")])->merge(
        makePage([(12, "0x12-different"), (11, "0x11-different")]),
        ~fromBlock=0,
        ~reportOnly=false,
      ),
    ).toEqual(
      Some({
        BufferPage.blockNumber: 11,
        storedHash: "0x11",
        receivedHash: "0x11-different",
      }),
    )
  })

  it("Rejects a response containing the same block number with different hashes", t => {
    let conflictingPage = makePage([(10, "0x10"), (10, "0x10-different")])
    t.expect(
      conflictingPage->BufferPage.responseConflict,
      ~message="The second observation of block 10 collides with the first one inside the same page",
    ).toEqual(
      Null.Value({
        BufferPage.blockNumber: 10,
        storedHash: "0x10",
        receivedHash: "0x10-different",
      }),
    )

    t.expect(
      makePage([(10, "0x10"), (10, "0x10")])->BufferPage.responseConflict,
      ~message="Duplicate block numbers with the same hash are accepted",
    ).toEqual(Null.Null)
  })

  it("rollback drops every hash above the valid block", t => {
    let store = mock(scannedHashesFixture)
    store->rollback(499)
    t.expect(store->hashedBlockNumbers(~fromBlock=0, ~belowBlock=1000)).toEqual([1, 50, 300])
    // The rolled-back range is refetched, so nothing above the target survives
    // to be compared against the disproved fork.
    store->rollback(299)
    t.expect({
      "blockNumbers": store->hashedBlockNumbers(~fromBlock=0, ~belowBlock=1000),
      "droppedHash": store->TestChainBuffer.blockHashAt(300),
    }).toEqual({
      "blockNumbers": [1, 50],
      "droppedHash": Null.Null,
    })
  })

  it("removing processed blocks below the reorg window keeps the window's", t => {
    let store = mock(scannedHashesFixture)
    // Progress at 500 with the window starting at 300: what a committed batch
    // removes.
    store->ChainBuffer.removeBlocksInBlockRange(~fromBlock=0, ~toBlock=299)
    t.expect({
      "blockNumbers": store->hashedBlockNumbers(~fromBlock=0, ~belowBlock=1000),
      "prunedHash": store->TestChainBuffer.blockHashAt(50),
      "keptHash": store->TestChainBuffer.blockHashAt(300),
    }).toEqual({
      "blockNumbers": [300, 500],
      "prunedHash": Null.Null,
      "keptHash": Null.Value("0x789"),
    })
  })

  it("Correctly finds the latest valid scanned block", t => {
    let store = mock(scannedHashesFixture)
    let latestValid = pairs =>
      store->ChainBuffer.findLatestBlockWithMatchingHash(
        makePage(pairs),
        pairs->Array.map(((n, _)) => n),
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
