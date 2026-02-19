open RescriptMocha

describe("E2E blockLag tests", () => {
  Async.it(
    "Chain with blockLag=1 should not be marked as synced to head",
    async () => {
      let sourceMock = Mock.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let indexerMock = await Mock.Indexer.make(
        ~chains=[
          {
            chain: #1337,
            sourceConfig: Config.CustomSources([sourceMock.source]),
            blockLag: 1,
          },
        ],
      )
      await Utils.delay(0)

      // Enter reorg threshold the standard way:
      // knownHeight=300, maxReorgDepth=200, so initial fetch is blocks 1-100
      await Mock.Helper.initialEnterReorgThreshold(~indexerMock, ~sourceMock)

      Assert.deepEqual(
        await indexerMock.metric("envio_reorg_threshold"),
        [{value: "1", labels: Js.Dict.empty()}],
        ~message="Should be in reorg threshold",
      )

      // Wait for the next query dispatch after entering reorg threshold
      await Utils.delay(0)
      await Utils.delay(0)
      await Utils.delay(0)
      await Utils.delay(0)

      // After entering reorg threshold, a new height poll fires.
      // Resolve it so the indexer can proceed.
      sourceMock.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // After entering reorg threshold, blockLag is updated to chainConfig.blockLag=1.
      // Resolve the pending fetch with items up to block 299 (knownHeight - blockLag).
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
          },
        ],
        ~latestFetchedBlockNumber=299,
      )
      await indexerMock.getBatchWritePromise()

      // With blockLag=1, progressBlockNumber=299 < knownHeight=300,
      // so isProgressAtHead remains false and chain is NOT synced to head.
      Assert.deepEqual(
        await indexerMock.metric("hyperindex_synced_to_head"),
        [{value: "0", labels: Js.Dict.empty()}],
        ~message="Chain with blockLag=1 should NOT be synced to head because progress (299) < knownHeight (300)",
      )

      // Wait for next query dispatch
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock.resolveGetHeightOrThrow(301)
      await Utils.delay(0)
      await Utils.delay(0)

      // Advance chain height to 301 and resolve fetch up to block 300.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=300,
        ~knownHeight=301,
      )
      await indexerMock.getBatchWritePromise()

      // Still not synced: progressBlockNumber=300 < knownHeight=301
      Assert.deepEqual(
        await indexerMock.metric("hyperindex_synced_to_head"),
        [{value: "0", labels: Js.Dict.empty()}],
        ~message="Chain with blockLag=1 should still NOT be synced after height advances",
      )
    },
  )
})
