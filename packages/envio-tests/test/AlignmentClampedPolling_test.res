open Vitest

// Chain 1's first query is held in flight, so its frontier stays at 0% and it
// anchors cross-chain alignment. Chain 2, once past 20% of its own range, is
// clamped to nothing: no query of its own, nothing ready, nothing in flight.
let chainYaml = id =>
  `
  - id: ${id->Int.toString}
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: alignment-clamped-polling
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${[1, 2]->Array.map(chainYaml)->Array.join("")}
`,
)

describe("A chain the alignment clamp leaves with nothing to query", () => {
  scenario->Scenario.it("keeps polling for new blocks", ~sources=[{chain: 1}, {chain: 2}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let anchor = source(1)
    let clamped = source(2)
    anchor.resolveGetHeightOrThrow(1000)
    await clamped.expectNewHeightCalls(1)
    clamped.resolveGetHeightOrThrow(1000)
    await anchor.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
    await clamped.expectItemsQueries([
      {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 400})},
    ])
    await clamped.expectNewHeightCalls(1)
    await indexer.waitUntilIdle()
    t.expect(clamped.pendingItemsQueries).toEqual([])
  })
})
