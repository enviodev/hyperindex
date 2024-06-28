open Ava
open Belt
open ReorgDetection

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

test("Get Latest and Add Latest Work", (. t) => {
  t->Assert.deepEqual(.
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

  t->Assert.deepEqual(.
    Some(nextLastBlockScanned),
    lastBlockScannedHashes->LastBlockScannedHashes.getLatestLastBlockData,
  )
})

test("Earliest timestamp in threshold works as expected", (. t) => {
  t->Assert.deepEqual(.
    Some(789),
    lastBlockScannedHashes->LastBlockScannedHashes.getEarlistTimestampInThreshold(
      ~currentHeight=500,
    ),
  )
})

test("Pruning works as expected", (. t) => {
  let pruned =
    lastBlockScannedHashes->LastBlockScannedHashes.pruneStaleBlockData(~currentHeight=500)

  let expected = [(300, "0x789", 789), (500, "0x5432", 5432)]->intoLastBlockScannedHashesHelper

  t->Assert.deepEqual(. expected, pruned, ~message="Should prune up to the block threshold")

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

  t->Assert.deepEqual(.
    expected,
    prunedWithMinTimestamp,
    ~message="Should keep one range end before the earliestMultiChainTimestampInThreshold",
  )
})

test("Rolling back to matching hashes works as expected", (. t) => {
  let unusedBlockTimestamp = -1
  let blockNumbersAndHashes = [
    (1, "0x123", unusedBlockTimestamp),
    (50, "0x456", unusedBlockTimestamp),
    (300, "0x789differnt", unusedBlockTimestamp),
    (500, "0x5432differnt", unusedBlockTimestamp),
  ]->Array.map(((blockNumber, blockHash, blockTimestamp)): ReorgDetection.blockData => {
    blockNumber,
    blockHash,
    blockTimestamp,
  })

  let rolledBack =
    lastBlockScannedHashes
    ->LastBlockScannedHashes.rollBackToValidHash(~blockNumbersAndHashes)
    ->Result.getExn

  let expected = [(1, "0x123", 123), (50, "0x456", 456)]->intoLastBlockScannedHashesHelper

  t->Assert.deepEqual(. expected, rolledBack, ~message="Should prune up to the block threshold")
})
