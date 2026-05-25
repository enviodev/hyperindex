open Vitest

describe("Polling-stall loophole", () => {
  Async.it_fails(
    "Stalls polling when chain buffer is at the head but events not yet processed",
    async t => {
      let pollingInterval = 1
      let reducedPollingInterval = 10

      let source = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
        ~pollingInterval,
      )
      let _indexerMock = await MockIndexer.Indexer.make(
        ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([source.source])}],
        ~shouldRollbackOnReorg=false,
        ~reducedPollingInterval,
      )
      await Utils.delay(0)

      source.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Handler that never resolves keeps the batch in-progress,
      // so isReady stays false while the buffer sits at the head.
      let blockingHandler = async _ => {
        let _ = await Promise.make((_, _) => ())
      }
      source.resolveGetItemsOrThrow(
        [{blockNumber: 150, logIndex: 0, handler: blockingHandler}],
        ~latestFetchedBlockNumber=300,
      )

      await Utils.delay(5)

      let baseline = source.getHeightOrThrowCalls->Array.length

      let deadline = Date.now() +. 50.
      while Date.now() < deadline {
        source.resolveGetHeightOrThrow(300)
        await Utils.delay(2)
      }

      let newCalls = source.getHeightOrThrowCalls->Array.length - baseline

      t.expect(
        newCalls,
        ~message="Source polled too often: its buffer is at the head while the batch is still processing, so polling should be reduced",
      ).toBeLessThanOrEqual(2)
    },
  )
})
