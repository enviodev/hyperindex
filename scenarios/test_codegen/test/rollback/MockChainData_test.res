open Belt
open RescriptMocha
open Mocha

describe("Check that MockChainData works as expected", () => {
  let mockChainDataInit = MockChainData.make(
    ~chainConfig=Config.config->ChainMap.get(Chain_1337),
    ~maxBlocksReturned=3,
    ~blockTimestampInterval=25,
  )

  open ChainDataHelpers.Gravatar
  let mockChainData = [
    [],
    [
      NewGravatar.mkEventConstr(MockEvents.newGravatar1),
      NewGravatar.mkEventConstr(MockEvents.newGravatar2),
    ],
    [UpdatedGravatar.mkEventConstr(MockEvents.setGravatar1)],
    [UpdatedGravatar.mkEventConstr(MockEvents.setGravatar1)],
    [
      UpdatedGravatar.mkEventConstr(MockEvents.setGravatar2),
      NewGravatar.mkEventConstr(MockEvents.newGravatar3),
      UpdatedGravatar.mkEventConstr(MockEvents.setGravatar3),
    ],
  ]->Array.reduce(mockChainDataInit, (accum, next) => {
    accum->MockChainData.addBlock(~makeLogConstructors=next)
  })

  it("Creates correct number of blocks", () => {
    Assert.equal(
      mockChainData.blocks->Array.length,
      5,
      ~message="addBlock function created the incorrect number of blocks",
    )
  })
  it("Has unique block hashes", () => {
    let hasUniqueBlockHashes =
      mockChainData.blocks
      ->Array.map(block => block.blockHash)
      ->HashSet.String.fromArray
      ->HashSet.String.size == mockChainData.blocks->Array.length

    Assert.equal(
      hasUniqueBlockHashes,
      true,
      ~message="block hashes should be unique for each block",
    )
  })

  it("Increments blocks and logs correctly", () => {
    mockChainData.blocks
    ->Array.reduce(
      None,
      (accum, next) => {
        Assert.equal(
          next.blockNumber,
          accum->Option.mapWithDefault(
            0,
            ({MockChainData.blockNumber: blockNumber}) => blockNumber + 1,
          ),
          ~message="Block numbers should increment",
        )
        Assert.equal(
          next.blockTimestamp,
          accum->Option.mapWithDefault(
            0,
            ({MockChainData.blockTimestamp: blockTimestamp}) =>
              blockTimestamp + mockChainData.blockTimestampInterval,
          ),
          ~message="Block timestamp should increment by defined interval",
        )

        next.logs
        ->Array.reduce(
          -1,
          (accum, next) => {
            Assert.equal(
              next.eventBatchQueueItem.logIndex,
              accum + 1,
              ~message="Log indexes should increment in each block",
            )
            next.eventBatchQueueItem.logIndex
          },
        )
        ->ignore

        Some(next)
      },
    )
    ->ignore
  })
})
