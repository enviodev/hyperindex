open Vitest

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
      mock([
        (300, "0x789"),
        (50, "0x456"),
        (500, "0x5432"),
        (1, "0x123"),
      ])->BlockStore.getHashedBlockNumbers(~fromBlock=500 - 200, ~belowBlock=501),
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

  it("Rejects a response containing the same block number with different hashes", t => {
    let conflictingPage = makePage([(10, "0x10"), (10, "0x10-different")])
    t.expect(
      conflictingPage->BlockStore.responseConflict,
      ~message="The second observation of block 10 collides with the first one inside the same page",
    ).toEqual(
      Null.Value({
        BlockStore.blockNumber: 10,
        storedHash: "0x10",
        receivedHash: "0x10-different",
      }),
    )

    t.expect(
      makePage([(10, "0x10"), (10, "0x10")])->BlockStore.responseConflict,
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
      store->BlockStore.latestValidBlockFromStore(makePage(pairs), pairs->Array.map(((n, _)) => n))

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

// The production threshold arithmetic: ChainState derives merge/read/prune
// boundaries from (knownHeight, maxReorgDepth), where maxReorgDepth is the
// resumed-from-DB value and may differ from the config after a restart.
describe("ChainState reorg threshold", () => {
  let baseChainConfig = Config.load().chainMap->ChainMap.values->Utils.Array.firstUnsafe

  let makeChainState = (~knownHeight, ~maxReorgDepth, ~scannedHashes) => {
    let contractConfigs = IndexingAddresses.makeContractConfigs(~onEventRegistrations=[])
    let indexingAddresses = IndexingAddresses.make(~contractConfigs, ~addresses=[])
    let base = FetchState.make(
      ~onEventRegistrations=[],
      ~contractConfigs,
      ~addresses=[],
      ~onBlockRegistrations=[
        {
          Internal.index: 0,
          name: "reorg-threshold-test",
          chainId: baseChainConfig.id,
          startBlock: None,
          endBlock: None,
          interval: 1,
          handler: "mock onBlock handler"->(
            Utils.magic: string => Internal.onBlockArgs => promise<unit>
          ),
        },
      ],
      ~startBlock=0,
      ~endBlock=None,
      ~maxAddrInPartition=3,
      ~maxOnBlockBufferSize=10000,
      ~chainId=baseChainConfig.id,
      ~knownHeight=0,
    )
    let blockStore = BlockStore.make(~ecosystem=Svm, ~shouldChecksum=false)
    let seedPage = BlockStore.fromJs(
      scannedHashes->Array.map(((blockNumber, blockHash)): BlockStore.inputBlock => {
        blockNumber,
        blockHash,
      }),
      ~ecosystem=Svm,
      ~shouldChecksum=false,
    )
    switch blockStore->BlockStore.merge(seedPage, ~fromBlock=0, ~reportOnly=false) {
    | Null.Value(_) => JsError.throwWithMessage("Unexpected reorg detected in test setup")
    | Null.Null => ()
    }
    let fetchState = {...base, FetchState.knownHeight}
    let mockSource = MockIndexer.Source.make([], ~chain=#1)
    let cs = ChainState.make(
      ~chainConfig=baseChainConfig,
      ~fetchState,
      ~indexingAddresses,
      ~sourceManager=SourceManager.make(~sources=[mockSource.source], ~isRealtime=false),
      ~shouldRollbackOnReorg=true,
      ~maxReorgDepth,
      ~committedProgressBlockNumber=-1,
      ~blockStore,
      ~logger=Logging.getLogger(),
    )
    (cs, fetchState)
  }

  let scannedHashes = [(1, "0x1"), (50, "0x50"), (300, "0x300"), (500, "0x500")]

  it("getReorgThresholdBlockNumbersBelow derives the threshold from knownHeight and depth", t => {
    let thresholdBlocks = (~knownHeight, ~maxReorgDepth) => {
      let (cs, _) = makeChainState(~knownHeight, ~maxReorgDepth, ~scannedHashes)
      cs->ChainState.getReorgThresholdBlockNumbersBelow(~blockNumber=501)
    }

    t.expect({
      "sameDepth": thresholdBlocks(~knownHeight=500, ~maxReorgDepth=200),
      // The store was seeded with checkpoints scanned under depth 200; resuming
      // with a smaller or larger depth must re-derive the threshold, not reuse
      // the one the checkpoints were saved with.
      "shrunkDepth": thresholdBlocks(~knownHeight=500, ~maxReorgDepth=199),
      "grownDepth": thresholdBlocks(~knownHeight=500, ~maxReorgDepth=450),
      "clampedToZero": thresholdBlocks(~knownHeight=100, ~maxReorgDepth=200),
    }).toEqual({
      "sameDepth": [300, 500],
      "shrunkDepth": [500],
      "grownDepth": [50, 300, 500],
      "clampedToZero": [1, 50, 300, 500],
    })
  })

  it("registerReorgGuard compares hashes only at or above knownHeight - maxReorgDepth", t => {
    let registerConflictAt300 = (~knownHeight) => {
      let (cs, _) = makeChainState(~knownHeight=500, ~maxReorgDepth=200, ~scannedHashes)
      cs->ChainState.registerReorgGuard(
        ~blockStore=BlockStore.fromJs(
          [{BlockStore.blockNumber: 300, blockHash: "0x300-different"}],
          ~ecosystem=Svm,
          ~shouldChecksum=false,
        ),
        ~knownHeight,
      )
    }

    t.expect(
      registerConflictAt300(~knownHeight=500),
      ~message="Block 300 is exactly at the threshold, so the conflict is a reorg",
    ).toEqual(
      ReorgDetection.ReorgDetected({
        scannedBlock: {blockNumber: 300, blockHash: "0x300"},
        receivedBlock: {blockNumber: 300, blockHash: "0x300-different"},
      }),
    )
    t.expect(
      registerConflictAt300(~knownHeight=501),
      ~message="One block later 300 leaves the threshold and the conflict is ignored",
    ).toEqual(ReorgDetection.NoReorg)
  })

  it("applyBatchProgress prunes processed blocks but keeps in-threshold hashes", t => {
    let (cs, fetchState) = makeChainState(~knownHeight=500, ~maxReorgDepth=200, ~scannedHashes)
    let progressedChainsById = Dict.make()
    progressedChainsById->Utils.Dict.setByInt(
      baseChainConfig.id,
      (
        {
          batchSize: 0,
          progressBlockNumber: 500,
          sourceBlockNumber: 500,
          totalEventsProcessed: 0.,
          fetchState,
          isProgressAtHeadWhenBatchCreated: false,
        }: Batch.chainAfterBatch
      ),
    )
    let batch: Batch.t = {
      totalBatchSize: 0,
      items: [],
      progressedChainsById,
      isInReorgThreshold: true,
      checkpointIds: [],
      checkpointChainIds: [],
      checkpointBlockNumbers: [],
      checkpointBlockHashes: [],
      checkpointEventsProcessed: [],
    }

    cs->ChainState.applyBatchProgress(~batch, ~blockTimestampName="timestamp")

    t.expect(
      cs
      ->ChainState.blockStore
      ->BlockStore.getHashedBlockNumbers(~fromBlock=0, ~belowBlock=1000),
      ~message="Processed blocks below knownHeight - maxReorgDepth lose their hashes; in-threshold ones stay",
    ).toEqual([300, 500])
  })
})
