open Vitest

// Repro: a multichain indexer never enters the reorg threshold.
//
// Entry is a one-time whole-indexer transition that requires EVERY chain to
// satisfy `isReadyToEnterReorgThreshold` at the same batch-completion check
// (BatchProcessing.res `Array.every`). Without a tolerance, a chain that reached
// its lagged head is un-readied the moment its head advances by a block. With
// more than one live chain the head of some chain is always advancing, so the
// conjunction is never observed and the indexer sits below the threshold forever.
// The reorg-threshold ready tolerance closes this: a chain stays ready while
// within `tolerance` blocks of the lagged head, so a small head advance during
// the cross-chain handoff no longer defers entry.
describe("PIN: multichain indexer enters the reorg threshold", () => {
  let waitNewHeightPoll = async (sourceMock: MockIndexer.Source.t, ~after) => {
    let attempts = ref(0)
    while sourceMock.getHeightOrThrowCalls->Array.length <= after && attempts.contents < 1000 {
      attempts := attempts.contents + 1
      await Utils.delay(0)
    }
    if sourceMock.getHeightOrThrowCalls->Array.length <= after {
      JsError.throwWithMessage("Timed out waiting for a new getHeightOrThrow poll")
    }
  }

  Async.it(
    "a chain whose head advances after reaching its lagged head still lets the indexer enter the threshold",
    async t => {
      // Two chains, each lagging maxReorgDepth (200) below head before the
      // threshold. Head starts at 1000, so the pre-threshold head is 800.
      let chainA = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#100,
      )
      let chainB = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )

      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {chain: #100, sourceConfig: Config.CustomSources([chainA.source]), maxReorgDepth: 200, blockLag: 0},
          {chain: #1337, sourceConfig: Config.CustomSources([chainB.source]), maxReorgDepth: 200, blockLag: 0},
        ],
        ~reorgThresholdReadyTolerance=100,
        ~reducedPollingInterval=1,
        ~targetBufferSize=100,
      )
      await Utils.delay(0)

      let initialHeightPolls = chainA.getHeightOrThrowCalls->Array.length
      chainA.resolveGetHeightOrThrow(1000)
      chainB.resolveGetHeightOrThrow(1000)
      await Utils.delay(0)
      await Utils.delay(0)

      // Chain A wins the initial priority tie and fetches to its pre-threshold
      // head (block 800), seeding a density signal from its events.
      await MockIndexer.Helper.waitItemsQuery(chainA)
      t.expect(
        chainA.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="chain A first fetches from its start block",
      ).toEqual([1])
      let densitySeed: array<MockIndexer.Source.itemMock> = Array.fromInitializer(~length=100, i => {
        MockIndexer.Source.blockNumber: 1 + i * 3,
        logIndex: 0,
      })
      chainA.resolveGetItemsOrThrow(densitySeed, ~latestFetchedBlockNumber=800, ~knownHeight=1000)
      await indexerMock.getBatchWritePromise()

      // Chain A is now at its lagged head with an empty buffer — momentarily
      // ready. Chain B has not responded, so the entry check fails here.
      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="cannot enter while chain B is still backfilling",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Chain A's head advances while it idles at its lagged head, so its frontier
      // (800) now trails the lagged head (801). Without a tolerance this would
      // un-ready chain A and defer entry; the 100-block tolerance keeps it ready.
      // (Chain A cannot re-query 801 yet — chain B holds the shared fetch budget.)
      await waitNewHeightPoll(chainA, ~after=initialHeightPolls)
      chainA.resolveGetHeightOrThrow(1001)
      await Utils.delay(0)
      await Utils.delay(0)

      // Chain B now reaches its own pre-threshold head and produces a batch,
      // triggering the whole-indexer entry check.
      await MockIndexer.Helper.waitItemsQuery(chainB)
      t.expect(
        chainB.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="chain B first fetches from its start block",
      ).toEqual([1])
      chainB.resolveGetItemsOrThrow(
        [{MockIndexer.Source.blockNumber: 800, logIndex: 0}],
        ~latestFetchedBlockNumber=800,
        ~knownHeight=1000,
      )
      await indexerMock.getBatchWritePromise()

      // Both chains are within the tolerance of their lagged heads, so the indexer
      // enters — even though chain A's head advanced past its frontier before
      // chain B caught up.
      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="the indexer enters the threshold with both chains within the tolerance of head",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )

  Async.it(
    "enters while still within the configured tolerance of the lagged head",
    async t => {
      let source = MockIndexer.Source.make(
        [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        ~chain=#1337,
      )
      let indexerMock = await MockIndexer.Indexer.make(
        ~chains=[
          {chain: #1337, sourceConfig: Config.CustomSources([source.source]), maxReorgDepth: 200, blockLag: 0},
        ],
        ~reorgThresholdReadyTolerance=100,
        ~reducedPollingInterval=1,
        ~targetBufferSize=100,
      )
      await Utils.delay(0)

      source.resolveGetHeightOrThrow(1000)
      await MockIndexer.Helper.waitItemsQuery(source)
      // Pre-threshold blockLag is 200, so the chain queries up to block 800.
      t.expect(
        source.getItemsOrThrowCalls->Array.map(call => call.payload["toBlock"]),
        ~message="pre-threshold query stops at the lagged head",
      ).toEqual([Some(800)])

      // Respond 50 blocks short of the lagged head (750 < 800) — within the
      // 100-block tolerance, so the chain enters despite not reaching 800 exactly.
      source.resolveGetItemsOrThrow(
        [{MockIndexer.Source.blockNumber: 750, logIndex: 0}],
        ~latestFetchedBlockNumber=750,
        ~knownHeight=1000,
      )
      await indexerMock.getBatchWritePromise()

      t.expect(
        await indexerMock.metric("envio_reorg_threshold"),
        ~message="enters within the tolerance below the lagged head",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )
})
