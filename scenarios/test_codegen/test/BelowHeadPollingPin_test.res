open Vitest

// PIN test — reproduces the exact production stall fixed by the kebggn commit
// "Keep below-head chains polling instead of dropping them (NothingToQuery)".
//
// When one chain falls far behind and its query reservation drains the shared
// fetch-buffer budget, another chain that is below its OWN head but starved of
// budget emits no query this tick. Being below head it also won't wait for a new
// block, so FetchState.getNextQuery returns NothingToQuery. CrossChainState's
// checkAndFetch never DISPATCHES NothingToQuery, so that chain stops querying AND
// stops polling getHeightOrThrow — its head tracking freezes and it goes fully
// silent. In production this looked like buffer=0, one chain still polling, and
// every other chain dead.
//
// This test asserts the FIXED behavior: the starved below-head chain must keep
// polling getHeightOrThrow. It is red on the unfixed scheduler (the follower
// never re-polls) and green once the below-head chain is dispatched as
// WaitingForNewBlock instead of being dropped.
describe("PIN: below-head chain keeps polling when starved of budget", () => {
  Async.it(
    "starved near-head follower keeps polling while a leader backfills a large range",
    async t => {
      let leader = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let follower = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {chain: #1337, sourceConfig: Config.CustomSources([leader.source])},
          {chain: #100, sourceConfig: Config.CustomSources([follower.source])},
        ],
        ~shouldRollbackOnReorg=false,
        // Small shared pool so the leader's backlog reservation drains it and
        // leaves the follower with no budget this tick.
        ~targetBufferSize=1000,
      )
      await Utils.delay(0)

      // Phase 1: both chains catch up to head (block 100) and become realtime.
      // A couple of events each seed a density signal so the leader's later
      // backlog is sized (and reserved) against real density.
      leader.resolveGetHeightOrThrow(100)
      follower.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      await Utils.delay(0)

      leader.resolveGetItemsOrThrow(
        [{blockNumber: 20, logIndex: 0}, {blockNumber: 60, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
      )
      await indexerMock.getBatchWritePromise()
      follower.resolveGetItemsOrThrow(
        [{blockNumber: 20, logIndex: 0}, {blockNumber: 60, logIndex: 0}],
        ~latestFetchedBlockNumber=100,
      )
      await indexerMock.getBatchWritePromise()

      t.expect(
        await indexerMock.metric("hyperindex_synced_to_head"),
        ~message="both chains reach realtime",
      ).toEqual([{value: "1", labels: Dict.make()}])

      // Both chains are now at head, parked on a realtime getHeightOrThrow poll.
      let followerPollsBefore = follower.getHeightOrThrowCalls->Array.length

      // Phase 2: divergent new heights. The leader jumps far ahead (a large
      // backlog whose reservation drains the shared budget); the follower advances
      // only slightly past its own head, so it is below head but gets no budget.
      leader.resolveGetHeightOrThrow(1_000_000)
      follower.resolveGetHeightOrThrow(105)
      await Utils.delay(0)
      await Utils.delay(0)

      // Drive the leader's backfill for several ticks, keeping it far behind so it
      // stays the budget-draining leader. Each response re-runs the cross-chain
      // dispatch, re-evaluating the starved follower every tick.
      for _ in 0 to 4 {
        await MockIndexer.Helper.waitItemsQuery(leader)
        let call = leader.getItemsOrThrowCalls->Array.getUnsafe(0)
        let fromBlock = call.payload["fromBlock"]
        call.resolve(
          [{blockNumber: fromBlock + 20, logIndex: 0}, {blockNumber: fromBlock + 60, logIndex: 0}],
          ~latestFetchedBlockNumber=fromBlock + 99,
        )
        await indexerMock.getBatchWritePromise()
      }

      // The follower is below its own head (frontier 100 < head 105) but starved
      // of budget. It must keep polling for new blocks rather than going silent.
      t.expect(
        follower.getHeightOrThrowCalls->Array.length > followerPollsBefore,
        ~message="starved below-head follower keeps polling getHeightOrThrow",
      ).toBe(true)
    },
  )
})
