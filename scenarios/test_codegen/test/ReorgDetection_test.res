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

  let intoLastBlockScannedHashesHelper = arr =>
    arr
    ->Array.map(((blockNumber, blockHash, blockTimestamp)) => {
      blockNumber,
      blockHash,
      blockTimestamp,
    })
    ->LastBlockScannedHashes.makeWithData(~confirmedBlockThreshold=200)

  let lastBlockScannedHashes = lastBlockScannedHashesArr->intoLastBlockScannedHashesHelper

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

    let lastBlockScannedHashes =
      lastBlockScannedHashes->LastBlockScannedHashes.addLatestLastBlockData(
        ~lastBlockScannedData=nextLastBlockScanned,
      )

    Assert.deep_equal(
      Some(nextLastBlockScanned),
      lastBlockScannedHashes->LastBlockScannedHashes.getLatestLastBlockData,
    )
  })

  it("Earliest timestamp in threshold works as expected", () => {
    Assert.deep_equal(
      Some(789),
      lastBlockScannedHashes->LastBlockScannedHashes.getEarlistTimestampInThreshold(
        ~currentHeight=500,
      ),
    )
  })

  it("Pruning works as expected", () => {
    let pruned =
      lastBlockScannedHashes->LastBlockScannedHashes.pruneStaleBlockData(~currentHeight=500)

    let expected = [(300, "0x789", 789), (500, "0x5432", 5432)]->intoLastBlockScannedHashesHelper

    Assert.deep_equal(expected, pruned, ~message="Should prune up to the block threshold")

    let prunedWithMinTimestamp =
      lastBlockScannedHashes->LastBlockScannedHashes.pruneStaleBlockData(
        ~currentHeight=500,
        ~earliestMultiChainTimestampInThreshold=470,
      )
    let expected =
      [
        (50, "0x456", 456),
        (300, "0x789", 789),
        (500, "0x5432", 5432),
      ]->intoLastBlockScannedHashesHelper

    Assert.deep_equal(
      expected,
      prunedWithMinTimestamp,
      ~message="Should keep one range end before the earliestMultiChainTimestampInThreshold",
    )
  })

  it("Rolling back to matching hashes works as expected", () => {
    let unusedBlockTimestamp = -1
    let blockNumbersAndHashes = [
      (1, "0x123", unusedBlockTimestamp),
      (50, "0x456", unusedBlockTimestamp),
      (300, "0x789differnt", unusedBlockTimestamp),
      (500, "0x5432differnt", unusedBlockTimestamp),
    ]->Array.map(
      ((blockNumber, blockHash, blockTimestamp)): ReorgDetection.blockData => {
        blockNumber,
        blockHash,
        blockTimestamp,
      },
    )

    let rolledBack =
      lastBlockScannedHashes
      ->LastBlockScannedHashes.rollBackToValidHash(~blockNumbersAndHashes)
      ->Result.getExn

    let expected = [(1, "0x123", 123), (50, "0x456", 456)]->intoLastBlockScannedHashesHelper

    Assert.deep_equal(expected, rolledBack, ~message="Should prune up to the block threshold")
  })
})
