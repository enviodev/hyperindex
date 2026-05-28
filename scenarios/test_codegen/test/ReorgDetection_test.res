open Vitest

describe("Validate reorg detection functions", () => {
  let scannedHashesFixture = [(1, "0x123"), (50, "0x456"), (300, "0x789"), (500, "0x5432")]

  let pipeNoReorg = ((updated, reorgResult)) => {
    switch reorgResult {
    | ReorgDetection.ReorgDetected(_) => JsError.throwWithMessage("Unexpected reorg detected")
    | NoReorg => updated
    }
  }

  let mock = (arr, ~maxReorgDepth=200, ~shouldRollbackOnReorg=true) => {
    ReorgDetection.make(
      ~chainReorgCheckpoints=arr->Array.map(((
        blockNumber,
        blockHash,
      )): Internal.reorgCheckpoint => {
        chainId: 0, // It's not used
        checkpointId: 0n, // It's not used
        blockNumber,
        blockHash,
      }),
      ~maxReorgDepth,
      ~shouldRollbackOnReorg,
    )
  }

  it("getThresholdBlockNumbersBelowBlock works as expected", t => {
    t.expect(
      mock(
        scannedHashesFixture,
        ~maxReorgDepth=200,
      )->ReorgDetection.getThresholdBlockNumbersBelowBlock(~blockNumber=501, ~knownHeight=500),
      ~message="Both 300 and 500 should be included in the threshold and below 501",
    ).toEqual([300, 500])
    t.expect(
      mock(
        scannedHashesFixture,
        ~maxReorgDepth=200,
      )->ReorgDetection.getThresholdBlockNumbersBelowBlock(~blockNumber=501, ~knownHeight=501),
      ~message="If chain progresses one more block, 300 is not included in the threshold anymore",
    ).toEqual([500])
    t.expect(
      mock(
        scannedHashesFixture,
        ~maxReorgDepth=200,
      )->ReorgDetection.getThresholdBlockNumbersBelowBlock(~blockNumber=500, ~knownHeight=499),
      ~message="Returns blocks below 500 that are in threshold",
    ).toEqual([300])
    t.expect(
      mock(
        [(300, "0x789"), (50, "0x456"), (500, "0x5432"), (1, "0x123")],
        ~maxReorgDepth=200,
      )->ReorgDetection.getThresholdBlockNumbersBelowBlock(~blockNumber=501, ~knownHeight=500),
      ~message="The order of blocks doesn't matter when we create reorg detection object",
    ).toEqual([300, 500])
    t.expect(
      mock(
        scannedHashesFixture,
        ~maxReorgDepth=199,
      )->ReorgDetection.getThresholdBlockNumbersBelowBlock(~blockNumber=501, ~knownHeight=500),
      ~message="Possible to shrink maxReorgDepth",
    ).toEqual([500])
    t.expect(
      mock(
        scannedHashesFixture,
        ~maxReorgDepth=450,
      )->ReorgDetection.getThresholdBlockNumbersBelowBlock(~blockNumber=501, ~knownHeight=500),
      ~message="Possible to increase maxReorgDepth",
    ).toEqual([50, 300, 500])
  })

  let makeBlocks = (entries): dict<ReorgDetection.blockData> => {
    let d = Dict.make()
    entries->Array.forEach(((blockNumber, blockHash)) =>
      d->Dict.set(blockNumber->Int.toString, {ReorgDetection.blockNumber, blockHash})
    )
    d
  }

  it("The registerReorgGuard should correctly add scanned data", t => {
    let knownHeight = 500

    let reorgDetection =
      mock([], ~maxReorgDepth=500)
      ->ReorgDetection.registerReorgGuard(
        ~blockHashes=makeBlocks([(1, "0x123")]),
        ~knownHeight,
      )
      ->pipeNoReorg
      ->ReorgDetection.registerReorgGuard(
        ~blockHashes=makeBlocks([(1, "0x123"), (50, "0x456")]),
        ~knownHeight,
      )
      ->pipeNoReorg
      ->ReorgDetection.registerReorgGuard(
        ~blockHashes=makeBlocks([(50, "0x456"), (300, "0x789")]),
        ~knownHeight,
      )
      ->pipeNoReorg
      ->ReorgDetection.registerReorgGuard(
        ~blockHashes=makeBlocks([(300, "0x789"), (500, "0x5432")]),
        ~knownHeight,
      )
      ->pipeNoReorg

    t.expect(reorgDetection, ~message="Should have the same data as the mock").toEqual(
      mock(scannedHashesFixture, ~maxReorgDepth=500),
    )
  })

  it(
    "Block hashes registered from a single response are all added to reorg detection",
    t => {
      let knownHeight = 500
      let reorgDetection =
        mock([], ~maxReorgDepth=200)
        ->ReorgDetection.registerReorgGuard(
          ~blockHashes=makeBlocks([(350, "0x350"), (400, "0x400"), (450, "0x450")]),
          ~knownHeight,
        )
        ->pipeNoReorg

      t.expect(
        reorgDetection,
        ~message="Should add every entry in blockHashes that is within threshold",
      ).toEqual(mock([(350, "0x350"), (400, "0x400"), (450, "0x450")], ~maxReorgDepth=200))
    },
  )

  it("Entries outside the reorg threshold are skipped entirely", t => {
    let knownHeight = 500
    let reorgDetection =
      mock([], ~maxReorgDepth=200)
      ->ReorgDetection.registerReorgGuard(
        ~blockHashes=makeBlocks([(100, "0x100"), (400, "0x400")]),
        ~knownHeight,
      )
      ->pipeNoReorg

    t.expect(
      reorgDetection,
      ~message="100 is below threshold (300) and gets ignored; 400 is kept",
    ).toEqual(mock([(400, "0x400")], ~maxReorgDepth=200))
  })

  it("Should prune records outside of the reorg threshold on registering new data", t => {
    let reorgDetection =
      mock([(1, "0x1"), (2, "0x2"), (3, "0x3")], ~maxReorgDepth=2)
      ->ReorgDetection.registerReorgGuard(
        ~blockHashes=makeBlocks([(3, "0x3"), (4, "0x4")]),
        ~knownHeight=4,
      )
      ->pipeNoReorg

    t.expect(
      reorgDetection,
      ~message="Should prune 1 since it's outside of reorg threshold", // Keeping block n 2 is questionable
    ).toEqual(mock([(2, "0x2"), (3, "0x3"), (4, "0x4")], ~maxReorgDepth=2))
  })

  it("Shouldn't validate reorg detection if it's outside of the reorg threshold", t => {
    let reorgDetection =
      mock(scannedHashesFixture, ~maxReorgDepth=200)
      ->ReorgDetection.registerReorgGuard(
        ~blockHashes=makeBlocks([(20, "0x20-invalid"), (50, "0x50-invalid")]),
        ~knownHeight=500,
      )
      ->pipeNoReorg

    t.expect(
      reorgDetection,
      ~message="Prunes original blocks at 1 and 50. Entries below threshold are ignored entirely.",
    ).toEqual(
      mock(
        [(300, "0x789"), (500, "0x5432")],
        ~maxReorgDepth=200,
      ),
    )
  })

  it("Should detect reorg when a single received hash doesn't match the scanned block", t => {
    let receivedBlock: ReorgDetection.blockData = {
      blockNumber: 10,
      blockHash: "0x10",
    }
    let scannedBlock: ReorgDetection.blockData = {
      blockNumber: 10,
      blockHash: "0x10-invalid",
    }

    let blockHashes = makeBlocks([(10, "0x10")])

    t.expect(
      mock([(10, "0x10-invalid")], ~shouldRollbackOnReorg=true)->ReorgDetection.registerReorgGuard(
        ~blockHashes,
        ~knownHeight=10,
      ),
    ).toEqual((
      mock([(10, "0x10-invalid")]),
      ReorgDetected({
        scannedBlock,
        receivedBlock,
      }),
    ))

    t.expect(
      mock([(10, "0x10-invalid")], ~shouldRollbackOnReorg=false)->ReorgDetection.registerReorgGuard(
        ~blockHashes,
        ~knownHeight=10,
      ),
      ~message=`Correctly detects reorg when shouldRollbackOnReorg is false.
      But resets the state every time to drop invalid state (since it's not done by rollback)`,
    ).toEqual((
      mock([], ~shouldRollbackOnReorg=false),
      ReorgDetected({
        scannedBlock,
        receivedBlock,
      }),
    ))
  })

  it("Should detect reorg when a parent-block hash in the response doesn't match scanned data", t => {
    let blockHashes = makeBlocks([(10, "0x10"), (11, "0x11")])

    let hashes = mock([(10, "0x10-invalid")], ~maxReorgDepth=2)

    let reorgDetectionResult =
      hashes->ReorgDetection.registerReorgGuard(~blockHashes, ~knownHeight=11)

    t.expect(reorgDetectionResult).toEqual((
      mock([(10, "0x10-invalid")], ~maxReorgDepth=2),
      ReorgDetected({
        scannedBlock: {
          blockNumber: 10,
          blockHash: "0x10-invalid",
        },
        receivedBlock: {
          blockNumber: 10,
          blockHash: "0x10",
        },
      }),
    ))
  })

  it("rollbackToValidBlockNumber works as expected", t => {
    let reorgDetection = mock(scannedHashesFixture, ~maxReorgDepth=200)

    t.expect(
      reorgDetection->ReorgDetection.rollbackToValidBlockNumber(~blockNumber=500),
      ~message="Shouldn't prune anything when the latest block number is the valid one",
    ).toEqual(reorgDetection)
    t.expect(
      reorgDetection->ReorgDetection.rollbackToValidBlockNumber(~blockNumber=499),
      ~message="Shouldn't prune blocks outside of the threshold. Would be nice, but it doesn't matter",
    ).toEqual(mock([(1, "0x123"), (50, "0x456"), (300, "0x789")], ~maxReorgDepth=200))
  })

  it("Correctly finds the latest valid scanned block", t => {
    let unusedBlockTimestamp = -1
    let blockNumbersAndHashes = [
      (1, "0x123", unusedBlockTimestamp),
      (50, "0x456", unusedBlockTimestamp),
      (300, "0x789differnt", unusedBlockTimestamp),
      (500, "0x5432differnt", unusedBlockTimestamp),
    ]->Array.map(
      ((blockNumber, blockHash, blockTimestamp)): ReorgDetection.blockDataWithTimestamp => {
        blockNumber,
        blockHash,
        blockTimestamp,
      },
    )

    t.expect(
      mock(scannedHashesFixture, ~maxReorgDepth=500)->ReorgDetection.getLatestValidScannedBlock(
        ~blockNumbersAndHashes,
      ),
      ~message="Should return the latest non-different block if we assume that all blocks are in the threshold",
    ).toEqual(Some(50))
    t.expect(
      mock(scannedHashesFixture, ~maxReorgDepth=200)->ReorgDetection.getLatestValidScannedBlock(
        ~blockNumbersAndHashes=blockNumbersAndHashes->Array.slice(~start=2),
      ),
      ~message="Returns None if there's no valid block in threshold",
    ).toEqual(None)

    let blockNumbersAndHashes = [
      (1, "0x123", unusedBlockTimestamp),
      (50, "0x456", unusedBlockTimestamp),
      (300, "0x789differnt", unusedBlockTimestamp),
      (500, "0x5432", unusedBlockTimestamp),
    ]->Array.map(
      ((blockNumber, blockHash, blockTimestamp)): ReorgDetection.blockDataWithTimestamp => {
        blockNumber,
        blockHash,
        blockTimestamp,
      },
    )
    t.expect(
      mock(scannedHashesFixture, ~maxReorgDepth=500)->ReorgDetection.getLatestValidScannedBlock(
        ~blockNumbersAndHashes,
      ),
      ~message="Case when the different block is in between of valid ones",
    ).toEqual(Some(50))
    t.expect(
      mock(scannedHashesFixture, ~maxReorgDepth=200)->ReorgDetection.getLatestValidScannedBlock(
        ~blockNumbersAndHashes=[(500, "0x5432-different")]->Array.map(
          ((blockNumber, blockHash)): ReorgDetection.blockDataWithTimestamp => {
            blockNumber,
            blockHash,
            blockTimestamp: unusedBlockTimestamp,
          },
        ),
      ),
      ~message="Returns None if the different block is the last one in the threshold",
    ).toEqual(None)
  })
})
