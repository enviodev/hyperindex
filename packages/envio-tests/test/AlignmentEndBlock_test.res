open Vitest

// Chain 1 ends at block 500, half the head. At block 250 it is halfway through
// its own range, ahead of chain 2 at 400 of 1000, so chain 2 anchors the
// alignment line and runs unclamped while chain 1 waits at 20% past it.
let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: alignment-end-block
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    end_block: 500
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 2
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
)

let eventAtFirstBlock: MockSource.itemMock = {blockNumber: 1, logIndex: 0}

describe("Cross-chain alignment", () => {
  scenario->Scenario.it(
    "measures a chain's progress against its end block when it's below the head",
    ~sources=[{chain: 1}, {chain: 2}],
    async (~t, ~indexer, ~source) => {
      let endsEarly = source(1)
      let runsToHead = source(2)
      endsEarly.resolveGetHeightOrThrow(1000)
      runsToHead.resolveGetHeightOrThrow(1000)
      await runsToHead.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await endsEarly.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [eventAtFirstBlock], latestFetchedBlockNumber: 250})},
      ])
      await indexer.waitUntilIdle()
      let seen = [...endsEarly.pendingItemsQueries, ...runsToHead.pendingItemsQueries]
      await runsToHead.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [eventAtFirstBlock], latestFetchedBlockNumber: 400})},
      ])
      await indexer.waitUntilIdle()
      let newQueries = (mock: MockSource.t) =>
        mock
        ->MockSource.takeNewPendingItemsQueries(~seen)
        ->Array.map(query => (query.fromBlock, query.toBlock, query->MockSource.itemsTarget))
      // Both are probes bounded only by their item targets; the clamped chain's
      // target is the smaller one.
      t.expect((endsEarly->newQueries, runsToHead->newQueries)).toEqual((
        [(251, MockSource.Bounded(500), Some(1))],
        [(401, MockSource.Unbounded, Some(2))],
      ))
    },
  )
})
