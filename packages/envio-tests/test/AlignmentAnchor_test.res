open Vitest

// Two chains with no end block. The chain whose fetch frontier is furthest
// behind, as a share of its own range, anchors cross-chain alignment, and the
// other may fetch no further than 20% of its range past that line.
let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: alignment-anchor
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

let eventAt = (blockNumber): MockSource.itemMock => {blockNumber, logIndex: 0}

let newQueries = (mock: MockSource.t, ~seen) =>
  mock
  ->MockSource.takeNewPendingItemsQueries(~seen)
  ->Array.map(query => (query.fromBlock, query.toBlock, query->MockSource.itemsTarget))

describe("The cross-chain alignment anchor", () => {
  scenario->Scenario.it(
    "measures progress from the start block, not the first event",
    ~sources=[{chain: 1}, {chain: 2}],
    async (~t, ~indexer, ~source) => {
      let lateFirstEvent = source(1)
      let earlyFirstEvent = source(2)
      lateFirstEvent.resolveGetHeightOrThrow(1000)
      earlyFirstEvent.resolveGetHeightOrThrow(1000)
      await earlyFirstEvent.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await lateFirstEvent.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [eventAt(500)], latestFetchedBlockNumber: 600})},
      ])
      await indexer.waitUntilIdle()
      let seen = [...lateFirstEvent.pendingItemsQueries, ...earlyFirstEvent.pendingItemsQueries]
      await earlyFirstEvent.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [eventAt(1)], latestFetchedBlockNumber: 400})},
      ])
      await indexer.waitUntilIdle()

      // From block 1, chain 1 at 600 is 60% through and chain 2 at 400 is
      // behind it, so chain 2 anchors and chain 1 waits. Counted from its first
      // event at 500, chain 1 would read 20% and take the anchor instead.
      t.expect((lateFirstEvent->newQueries(~seen), earlyFirstEvent->newQueries(~seen))).toEqual((
        [],
        [(401, MockSource.Unbounded, Some(2))],
      ))
    },
  )
})
