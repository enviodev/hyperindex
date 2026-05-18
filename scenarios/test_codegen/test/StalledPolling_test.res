open Vitest

// Reproduction for a loophole in the polling-stall logic.
//
// `GlobalState.checkAndFetchForChain` enables `reducedPolling` only when
// `ChainFetcher.isReady` is true (i.e. `timestampCaughtUpToHeadOrEndblock`
// has been set). That flag only flips after a batch has been processed
// for the chain. A chain can have its buffer fetched all the way to the
// head while not a single event has been processed yet — e.g. in
// multichain Ordered mode where another chain's older `latestFetchedBlock`
// is blocking processing. In that state there's nothing useful to fetch
// for the at-head chain, but it keeps polling its source at the normal
// `pollingInterval`.
//
// This end-to-end test drives the loophole through the real
// `MockIndexer.Indexer` and observes Source A's polling cadence: when the
// stall is correctly applied the source should sit on
// `reducedPollingInterval` (60s) and accumulate no new height calls within
// the test window; with the bug it iterates every `pollingInterval` (1ms)
// and the call count climbs fast.

describe("Polling-stall loophole", () => {
  Async.it_fails(
    "Stalls polling on a chain whose buffer is at the head while another chain still backfills",
    async t => {
      let noopHandler = async _ => ()

      let sourceA = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
        ~pollingInterval=1,
      )
      let sourceB = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
        ~pollingInterval=1,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {chain: #1337, sourceConfig: Config.CustomSources([sourceA.source])},
          {chain: #100, sourceConfig: Config.CustomSources([sourceB.source])},
        ],
        ~multichain=Ordered,
        // Disable rollback-on-reorg so blockLag=0 (we can drive the chain
        // up to its head with low block numbers) and the second OR branch
        // of the `reducedPolling` formula is always false — isolating the
        // loophole to the `isReady` branch.
        ~shouldRollbackOnReorg=false,
      )
      await Utils.delay(0)

      sourceA.resolveGetHeightOrThrow(300)
      sourceB.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Chain A: one event at block 150 and the partition fully fetched
      // to the head (latestFetchedBlockNumber = knownHeight = 300).
      sourceA.resolveGetItemsOrThrow(
        [{blockNumber: 150, logIndex: 0, handler: noopHandler}],
        ~latestFetchedBlockNumber=300,
      )
      // Chain B: one event at block 50, partition still well behind head
      // (latestFetchedBlockNumber=100). Under Ordered multichain this
      // blocks A's event at 150 from being processed: A's
      // `timestampCaughtUpToHeadOrEndblock` stays `None`, so `isReady`
      // stays false, so `reducedPolling` stays false.
      sourceB.resolveGetItemsOrThrow(
        [{blockNumber: 50, logIndex: 0, handler: noopHandler}],
        ~latestFetchedBlockNumber=100,
      )

      // Wait for B's event at block 50 to be batched & processed.
      // A's event at 150 stays stuck in the buffer because B's
      // latestFetchedBlock (100) is still below 150.
      await indexerMock.getBatchWritePromise()
      // Let the follow-up NextQuery for A re-enter waitForNewBlock and
      // post the first pending getHeightOrThrow call.
      await Utils.delay(5)

      let baseline = sourceA.getHeightOrThrowCalls->Array.length

      // Drive Source A's polling loop for 50ms by resolving the pending
      // height with the same value. With `reducedPolling=false` (the bug)
      // the loop iterates every pollingInterval=1ms and the call count
      // grows rapidly. With `reducedPolling=true` (the fix) the loop
      // sleeps for reducedPollingInterval=60s and the count barely moves.
      let deadline = Date.now() +. 50.
      while Date.now() < deadline {
        try {
          sourceA.resolveGetHeightOrThrow(300)
        } catch {
        | _ => ()
        }
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
