open RescriptMocha
open Mocha
open Belt
open ReorgDetection

describe("Validate reorg detection functions", () => {
  let lastBlockScannedHashesArr = [
    (1, "0x123", 123),
    (50, "0x456", 456),
    (300, "0x789", 789),
    (500, "0x5432", 5432),
  ]
  // list{(50, "0x456", 456), (1, "0x123", 123)}
  ->Array.map(((blockNumber, blockHash, blockTimestamp)) => {
    blockNumber,
    blockHash,
    blockTimestamp,
  })
  let lastBlockScannedHashes =
    lastBlockScannedHashesArr->LastBlockScannedHashes.makeWithData(~confirmedBlockThreshold=200)

  it("Get Latest and Add Latest Work", () => {
    Assert.deep_equal(
      Some({blockNumber: 500, blockHash: "0x5432", blockTimestamp: 5432}),
      lastBlockScannedHashes->LastBlockScannedHashes.getLatestLastBlockData,
    )

    let nextLastBlockScanned = {
      blockNumber: 700,
      blockHash: "0x7654",
      blockTimestamp: 7654,
    }
    let {blockNumber, blockHash, blockTimestamp} = nextLastBlockScanned

    let lastBlockScannedHashes =
      lastBlockScannedHashes->LastBlockScannedHashes.addLatestLastBlockData(
        ~blockTimestamp,
        ~blockHash,
        ~blockNumber,
      )

    Assert.deep_equal(
      Some(nextLastBlockScanned),
      lastBlockScannedHashes->LastBlockScannedHashes.getLatestLastBlockData,
    )
  })

  it("Earliest timestamp in threshold works", () => {
    Assert.deep_equal(
      Some(789),
      lastBlockScannedHashes->LastBlockScannedHashes.getEarlistTimestampInThreshold(
        ~currentHeight=500,
      ),
    )
  })
})
