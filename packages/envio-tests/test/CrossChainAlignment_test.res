open Vitest

// Two chains share one buffer pool. The chain whose fetch frontier is furthest
// behind, as a share of its own range, anchors cross-chain alignment, and the
// other may fetch no further than 20% of its own range past that line.
let makeScenario = (~name, ~firstChainEndBlock=?) => {
  let chainYaml = (~id, ~endBlock) =>
    `
  - id: ${id->Int.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
${endBlock->Option.mapOr("", endBlock =>
        `    end_block: ${endBlock->Int.toString}\n`
      )}    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`
  Scenario.make(
    ~supervised=false,
    ~configYaml=`
name: ${name}
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainYaml(~id=1, ~endBlock=firstChainEndBlock)}${chainYaml(~id=2, ~endBlock=None)}
`,
  )
}

let sources: array<Scenario.sourceMock> = [{chain: 1}, {chain: 2}]

let eventAt = (blockNumber): MockSource.itemMock => {blockNumber, logIndex: 0}

let newQueries = (mock: MockSource.t, ~indexer, ~chainId, ~seen) =>
  mock
  ->MockSource.takeNewPendingItemsQueries(~seen)
  ->Array.map(query => (
    query.fromBlock,
    query.toBlock,
    indexer->QueryReservations.reservation(
      ~chainId,
      ~partitionId=query.partitionId,
      ~fromBlock=query.fromBlock,
    ),
  ))

// Chain 1 reaches `leaderFetchedTo` while chain 2's first query is held, then
// chain 2 reaches block 400. Returns the queries each chain issues after that.
let queriesOnceBothFetched = async (
  ~indexer: IndexerRunner.t,
  ~source: (int, ~index: int=?) => MockSource.t,
  ~leaderEventAt,
  ~leaderFetchedTo,
) => {
  let leader = source(1)
  let follower = source(2)
  leader.resolveGetHeightOrThrow(1000)
  follower.resolveGetHeightOrThrow(1000)
  await follower.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
  await leader.expectItemsQueries([
    {
      fromBlock: 1,
      reply: Respond({items: [eventAt(leaderEventAt)], latestFetchedBlockNumber: leaderFetchedTo}),
    },
  ])
  await indexer.waitUntilIdle()
  let seen = [...leader.pendingItemsQueries, ...follower.pendingItemsQueries]
  await follower.expectItemsQueries([
    {fromBlock: 1, reply: Respond({items: [eventAt(1)], latestFetchedBlockNumber: 400})},
  ])
  await indexer.waitUntilIdle()
  (
    leader->newQueries(~indexer, ~chainId=1, ~seen),
    follower->newQueries(~indexer, ~chainId=2, ~seen),
  )
}

describe("Cross-chain alignment", () => {
  makeScenario(
    ~name="alignment-clamped-polling",
  )->Scenario.it(
    "keeps a chain the clamp leaves with nothing to query polling for new blocks",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let anchor = source(1)
      let clamped = source(2)
      anchor.resolveGetHeightOrThrow(1000)
      await clamped.expectNewHeightCalls(1)
      clamped.resolveGetHeightOrThrow(1000)
      // The anchor's query is held, so it stays at 0%. Past 20% of its range,
      // the other chain has no query, nothing ready and nothing in flight.
      await anchor.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await clamped.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 400})},
      ])
      await clamped.expectNewHeightCalls(1)
      await indexer.waitUntilIdle()
      t.expect(clamped.pendingItemsQueries).toEqual([])
    },
  )

  makeScenario(
    ~name="alignment-first-event",
  )->Scenario.it("measures progress from the start block, not the first event", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    // From block 1, chain 1 at 600 is 60% through and chain 2 at 400 is
    // behind it, so chain 2 anchors and chain 1 waits. Counted from its first
    // event at 500, chain 1 would read 20% and take the anchor instead.
    t.expect(
      await queriesOnceBothFetched(~indexer, ~source, ~leaderEventAt=500, ~leaderFetchedTo=600),
    ).toEqual(([], [(401, MockSource.Unbounded, Some(2))]))
  })

  makeScenario(
    ~name="alignment-end-block",
    ~firstChainEndBlock=500,
  )->Scenario.it(
    "measures a chain's progress against its end block when it's below the head",
    ~sources,
    async (~t, ~indexer, ~source) => {
      // Chain 1 at 250 of its 500 end block is 50% through, ahead of chain 2 at
      // 400 of 1000, so chain 2 anchors. Both send probes, and the clamped
      // chain's reserves less of the pool.
      t.expect(
        await queriesOnceBothFetched(~indexer, ~source, ~leaderEventAt=1, ~leaderFetchedTo=250),
      ).toEqual(([(251, MockSource.Bounded(500), Some(1))], [(401, MockSource.Unbounded, Some(2))]))
    },
  )
})
