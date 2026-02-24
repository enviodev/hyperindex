open Vitest

describe("E2E blockLag tests", () => {
  Async.itWithTimeout(
    "Chain with blockLag=1 should be marked as synced to head when at knownHeight - blockLag",
    async t => {
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
      await Mock.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock)

      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="Should be in reorg threshold",
      ).toEqual([{value: "1", labels: Js.Dict.empty()}])

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
      // The indexer fetches from block 101 up to knownHeight - blockLag = 299.
      t.expect(
        sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
        ~message="Should request items from block 101 to 299 (knownHeight - blockLag)",
      ).toEqual(Some({"fromBlock": 101, "toBlock": Some(299), "retry": 0, "p": "0"}))

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

      // With blockLag=1, progressBlockNumber=299 >= knownHeight(300) - blockLag(1) = 299,
      // so isProgressAtHead is true and chain IS synced to head.
      t.expect(
        await indexerMock.metric("hyperindex_synced_to_head"),
        ~message="Chain with blockLag=1 should be synced to head because progress (299) >= knownHeight (300) - blockLag (1)",
      ).toEqual([{value: "1", labels: Js.Dict.empty()}])

      // Wait for next query dispatch
      await Utils.delay(0)
      await Utils.delay(0)

      sourceMock.resolveGetHeightOrThrow(301)
      await Utils.delay(0)
      await Utils.delay(0)

      // Should request from block 300 up to knownHeight - blockLag = 300.
      t.expect(
        sourceMock.getItemsOrThrowCalls->Js.Array2.map(c => c.payload)->Utils.Array.last,
        ~message="Should request items from block 300 to 300 (knownHeight 301 - blockLag 1)",
      ).toEqual(Some({"fromBlock": 300, "toBlock": Some(300), "retry": 0, "p": "0"}))

      // Advance chain height to 301 and resolve fetch up to block 300.
      sourceMock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=300,
        ~knownHeight=301,
      )
      await indexerMock.getBatchWritePromise()

      // Still synced: progressBlockNumber=300 >= knownHeight(301) - blockLag(1) = 300
      t.expect(
        await indexerMock.metric("hyperindex_synced_to_head"),
        ~message="Chain with blockLag=1 should still be synced after height advances",
      ).toEqual([{value: "1", labels: Js.Dict.empty()}])
    },
    10_000,
  )
})
