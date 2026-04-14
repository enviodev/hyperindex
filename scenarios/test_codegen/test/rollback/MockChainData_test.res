
open Vitest

describe("Check that MockChainData works as expected", () => {
  let mockChainDataInit = MockChainData.make(
    ~chainConfig=Indexer.Generated.makeGeneratedConfig().chainMap->ChainMap.get(MockConfig.chain1337),
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

  it("Creates correct number of blocks", t => {
    t.expect(
      mockChainData.blocks->Array.length,
      ~message="addBlock function created the incorrect number of blocks",
    ).toBe(5)
  })
  it("Has unique block hashes", t => {
    let hasUniqueBlockHashes =
      mockChainData.blocks
      ->Array.map(block => block.blockHash)
      ->Belt.HashSet.String.fromArray
      ->Belt.HashSet.String.size == mockChainData.blocks->Array.length

    t.expect(
      hasUniqueBlockHashes,
      ~message="block hashes should be unique for each block",
    ).toBe(true)
  })

  it("Increments blocks and logs correctly", t => {
    mockChainData.blocks
    ->Array.reduce(
      None,
      (accum, next) => {
        t.expect(
          next.blockNumber,
          ~message="Block numbers should increment",
        ).toBe(
          accum->Option.mapOr(
            0,
            ({MockChainData.blockNumber: blockNumber}) => blockNumber + 1,
          ),
        )
        t.expect(
          next.blockTimestamp,
          ~message="Block timestamp should increment by defined interval",
        ).toBe(
          accum->Option.mapOr(
            0,
            ({MockChainData.blockTimestamp: blockTimestamp}) =>
              blockTimestamp + mockChainData.blockTimestampInterval,
          ),
        )

        next.logs
        ->Array.reduce(
          -1,
          (accum, next) => {
            let eventItem = next.item->Internal.castUnsafeEventItem
            t.expect(
              eventItem.logIndex,
              ~message="Log indexes should increment in each block",
            ).toBe(accum + 1)
            eventItem.logIndex
          },
        )
        ->ignore

        Some(next)
      },
    )
    ->ignore
  })
})
