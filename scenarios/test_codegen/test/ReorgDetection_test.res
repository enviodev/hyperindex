open RescriptMocha

open Belt
open ReorgDetection

describe("Validate reorg detection functions", () => {
  let scannedHashesFixture = [(1, "0x123"), (50, "0x456"), (300, "0x789"), (500, "0x5432")]

  let mock = (arr, ~confirmedBlockThreshold=200) => {
    arr
    ->Array.map(((blockNumber, blockHash)) => {
      blockNumber,
      blockHash,
    })
    ->LastBlockScannedHashes.makeWithData(~confirmedBlockThreshold)
  }

  it("getThresholdBlockNumbers works as expected", () => {
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=200,
      )->ReorgDetection.LastBlockScannedHashes.getThresholdBlockNumbers(~currentBlockHeight=500),
      [300, 500],
      ~message="Both 300 and 500 should be included in the threshold",
    )
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=200,
      )->ReorgDetection.LastBlockScannedHashes.getThresholdBlockNumbers(~currentBlockHeight=501),
      [500],
      ~message="If chain progresses one more block, 300 is not included in the threshold anymore",
    )
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=200,
      )->ReorgDetection.LastBlockScannedHashes.getThresholdBlockNumbers(~currentBlockHeight=499),
      [300, 500],
      ~message="We don't prevent blocks higher than currentBlockHeight from being included in the threshold, since the case is not possible",
    )
    Assert.deepEqual(
      mock(
        [(300, "0x789"), (50, "0x456"), (500, "0x5432"), (1, "0x123")],
        ~confirmedBlockThreshold=200,
      )->ReorgDetection.LastBlockScannedHashes.getThresholdBlockNumbers(~currentBlockHeight=500),
      [300, 500],
      ~message="The order of blocks doesn't matter when we create reorg detection object",
    )
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=199,
      )->ReorgDetection.LastBlockScannedHashes.getThresholdBlockNumbers(~currentBlockHeight=500),
      [500],
      ~message="Possible to shrink confirmedBlockThreshold",
    )
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=450,
      )->ReorgDetection.LastBlockScannedHashes.getThresholdBlockNumbers(~currentBlockHeight=500),
      [50, 300, 500],
      ~message="Possible to increase confirmedBlockThreshold",
    )
  })

  it("The registerReorgGuard should correctly add scanned data", () => {
    let currentBlockHeight = 500

    let reorgDetection =
      ReorgDetection.LastBlockScannedHashes.empty(~confirmedBlockThreshold=500)
      ->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
        ~reorgGuard={
          lastBlockScannedData: {
            blockNumber: 1,
            blockHash: "0x123",
          },
          firstBlockParentNumberAndHash: None,
        },
        ~currentBlockHeight,
      )
      ->Result.getExn
      ->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
        ~reorgGuard={
          lastBlockScannedData: {
            blockNumber: 50,
            blockHash: "0x456",
          },
          firstBlockParentNumberAndHash: Some({
            blockNumber: 1,
            blockHash: "0x123",
          }),
        },
        ~currentBlockHeight,
      )
      ->Result.getExn
      ->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
        ~reorgGuard={
          lastBlockScannedData: {
            blockNumber: 300,
            blockHash: "0x789",
          },
          firstBlockParentNumberAndHash: Some({
            blockNumber: 50,
            blockHash: "0x456",
          }),
        },
        ~currentBlockHeight,
      )
      ->Result.getExn
      ->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
        ~reorgGuard={
          lastBlockScannedData: {
            blockNumber: 500,
            blockHash: "0x5432",
          },
          firstBlockParentNumberAndHash: Some({
            blockNumber: 300,
            blockHash: "0x789",
          }),
        },
        ~currentBlockHeight,
      )
      ->Result.getExn

    Assert.deepEqual(
      reorgDetection,
      mock(scannedHashesFixture, ~confirmedBlockThreshold=500),
      ~message="Should have the same data as the mock",
    )
  })

  it(
    "The firstBlockParentNumberAndHash in reorg guard should add a scanned block data to reorg detection",
    () => {
      let currentBlockHeight = 500
      let reorgDetection =
        ReorgDetection.LastBlockScannedHashes.empty(~confirmedBlockThreshold=200)
        ->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
          ~reorgGuard={
            lastBlockScannedData: {
              blockNumber: 50,
              blockHash: "0x456",
            },
            firstBlockParentNumberAndHash: Some({
              blockNumber: 1,
              blockHash: "0x123",
            }),
          },
          ~currentBlockHeight,
        )
        ->Result.getExn

      Assert.deepEqual(
        reorgDetection,
        mock([(1, "0x123"), (50, "0x456")], ~confirmedBlockThreshold=200),
        ~message="Should add two records. One for lastBlockScannedData and one for firstBlockParentNumberAndHash",
      )
    },
  )

  it("Should prune records outside of the reorg threshold on registering new data", () => {
    let reorgDetection =
      mock([(1, "0x1"), (2, "0x2"), (3, "0x3")], ~confirmedBlockThreshold=2)
      ->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
        ~reorgGuard={
          lastBlockScannedData: {
            blockNumber: 4,
            blockHash: "0x4",
          },
          firstBlockParentNumberAndHash: Some({
            blockNumber: 3,
            blockHash: "0x3",
          }),
        },
        ~currentBlockHeight=4,
      )
      ->Result.getExn

    Assert.deepEqual(
      reorgDetection,
      mock([(2, "0x2"), (3, "0x3"), (4, "0x4")], ~confirmedBlockThreshold=2),
      ~message="Should prune 1 since it's outside of reorg threshold", // Keeping block n 2 is questionable
    )
  })

  it("Shouldn't validate reorg detection if it's outside of the reorg threshold", () => {
    let reorgDetection =
      mock(scannedHashesFixture, ~confirmedBlockThreshold=200)
      ->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
        ~reorgGuard={
          lastBlockScannedData: {
            blockNumber: 50,
            blockHash: "0x50-invalid",
          },
          firstBlockParentNumberAndHash: Some({
            blockNumber: 20,
            blockHash: "0x20-invalid",
          }),
        },
        ~currentBlockHeight=500,
      )
      ->Result.getExn

    Assert.deepEqual(
      reorgDetection,
      mock(
        [(20, "0x20-invalid"), (50, "0x50-invalid"), (300, "0x789"), (500, "0x5432")],
        ~confirmedBlockThreshold=200,
      ),
      ~message="Prunes original blocks at 1 and 50. It writes invalid data for block 20 and 50, but they are outside of the reorg thershold, so we don't care",
    )
  })

  it("Should detect reorg when lastBlockScannedData hash doesn't match the scanned block", () => {
    let reorgGuard = {
      lastBlockScannedData: {
        blockNumber: 10,
        blockHash: "0x10-invalid",
      },
      firstBlockParentNumberAndHash: None,
    }

    let reorgDetectionResult =
      mock(
        [(10, "0x10")],
        ~confirmedBlockThreshold=2,
      )->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
        ~reorgGuard,
        ~currentBlockHeight=10,
      )

    Assert.deepEqual(
      reorgDetectionResult,
      Error({
        scannedBlock: {
          blockNumber: 10,
          blockHash: "0x10",
        },
        receivedBlock: reorgGuard.lastBlockScannedData,
      }),
    )
  })

  it(
    "Should detect reorg when firstBlockParentNumberAndHash hash doesn't match the scanned block",
    () => {
      let reorgGuard = {
        lastBlockScannedData: {
          blockNumber: 11,
          blockHash: "0x11",
        },
        firstBlockParentNumberAndHash: Some({
          blockNumber: 10,
          blockHash: "0x10-invalid",
        }),
      }

      let reorgDetectionResult =
        mock(
          [(10, "0x10")],
          ~confirmedBlockThreshold=2,
        )->ReorgDetection.LastBlockScannedHashes.registerReorgGuard(
          ~reorgGuard,
          ~currentBlockHeight=11,
        )

      Assert.deepEqual(
        reorgDetectionResult,
        Error({
          scannedBlock: {
            blockNumber: 10,
            blockHash: "0x10",
          },
          receivedBlock: {
            blockNumber: 10,
            blockHash: "0x10-invalid",
          },
        }),
      )
    },
  )

  it("rollbackToValidBlockNumber works as expected", () => {
    let reorgDetection = mock(scannedHashesFixture, ~confirmedBlockThreshold=200)

    Assert.deepEqual(
      reorgDetection->LastBlockScannedHashes.rollbackToValidBlockNumber(~blockNumber=500),
      reorgDetection,
      ~message="Shouldn't prune anything when the latest block number is the valid one",
    )
    Assert.deepEqual(
      reorgDetection->LastBlockScannedHashes.rollbackToValidBlockNumber(~blockNumber=499),
      mock([(1, "0x123"), (50, "0x456"), (300, "0x789")], ~confirmedBlockThreshold=200),
      ~message="Shouldn't prune blocks outside of the threshold. Would be nice, but it doesn't matter",
    )
  })

  it("Correctly finds the latest valid scanned block", () => {
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

    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=500,
      )->LastBlockScannedHashes.getLatestValidScannedBlock(
        ~blockNumbersAndHashes,
        ~currentBlockHeight=500,
      ),
      Some({
        blockNumber: 50,
        blockHash: "0x456",
        blockTimestamp: unusedBlockTimestamp,
      }),
      ~message="Should return the latest non-different block if we assume that all blocks are in the threshold",
    )
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=200,
      )->LastBlockScannedHashes.getLatestValidScannedBlock(
        ~blockNumbersAndHashes,
        ~currentBlockHeight=500,
      ),
      None,
      ~message="Returns None if there's no valid block in threshold",
    )

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
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=500,
      )->LastBlockScannedHashes.getLatestValidScannedBlock(
        ~blockNumbersAndHashes,
        ~currentBlockHeight=500,
      ),
      Some({
        blockNumber: 50,
        blockHash: "0x456",
        blockTimestamp: unusedBlockTimestamp,
      }),
      ~message="Case when the different block is in between of valid ones",
    )
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=200,
      )->LastBlockScannedHashes.getLatestValidScannedBlock(
        ~blockNumbersAndHashes,
        ~currentBlockHeight=500,
      ),
      None,
      ~message="Returns None if the different block is the last one in the threshold",
    )
    Assert.deepEqual(
      mock(
        scannedHashesFixture,
        ~confirmedBlockThreshold=200,
      )->LastBlockScannedHashes.getLatestValidScannedBlock(
        ~blockNumbersAndHashes,
        ~currentBlockHeight=501,
      ),
      Some({
        blockNumber: 500,
        blockHash: "0x5432",
        blockTimestamp: unusedBlockTimestamp,
      }),
      ~message="Ignores invalid blocks outside of the threshold",
    )
  })
})
