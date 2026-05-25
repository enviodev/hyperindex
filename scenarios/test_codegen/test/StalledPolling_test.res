open Vitest

describe("Polling-stall loophole", () => {
  Async.it_fails(
    "Stalls polling on a chain whose buffer is at the head while another chain still backfills",
    async t => {
      let pollingInterval = 1
      let reducedPollingInterval = 10
      let noopHandler = async _ => ()

      let sourceA = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
        ~pollingInterval,
      )
      let sourceB = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
        ~pollingInterval,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {chain: #1337, sourceConfig: Config.CustomSources([sourceA.source])},
          {chain: #100, sourceConfig: Config.CustomSources([sourceB.source])},
        ],
        ~multichain=Ordered,
        ~shouldRollbackOnReorg=false,
        ~reducedPollingInterval,
      )
      await Utils.delay(0)

      sourceA.resolveGetHeightOrThrow(300)
      sourceB.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      sourceA.resolveGetItemsOrThrow(
        [{blockNumber: 150, logIndex: 0, handler: noopHandler}],
        ~latestFetchedBlockNumber=300,
      )
      sourceB.resolveGetItemsOrThrow(
        [{blockNumber: 50, logIndex: 0, handler: noopHandler}],
        ~latestFetchedBlockNumber=100,
      )

      await indexerMock.getBatchWritePromise()
      await Utils.delay(5)

      let baseline = sourceA.getHeightOrThrowCalls->Array.length

      let deadline = Date.now() +. 50.
      while Date.now() < deadline {
        sourceA.resolveGetHeightOrThrow(300)
        await Utils.delay(2)
      }

      let newCalls = sourceA.getHeightOrThrowCalls->Array.length - baseline

      t.expect(
        newCalls,
        ~message="Source A polled too often: its buffer is at the head while Source B backfills, so polling should be reduced",
      ).toBeLessThanOrEqual(2)
    },
  )
})
