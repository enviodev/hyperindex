open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: block-throttle
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    block_throttle: 5
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

describe("E2E blockThrottle tests", () => {
  scenario->Scenario.it(
    "Chain at the head with blockThrottle=5 fetches again only once the head is 5 blocks further",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~sourceTiming={reducedPollingInterval: 1},
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Scenario.enterReorgThreshold(~indexer, ~source=sourceMock)

      sourceMock.resolveGetHeightOrThrow(300)
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 101,
          toBlock: Unbounded,
          retryCount: 0,
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
      ])
      await indexer.getBatchWritePromise()

      // At the head (300). Four new blocks are not enough: the wait keeps
      // polling instead of handing 304 to the fetch loop.
      sourceMock.resolveGetHeightOrThrow(304)
      let heightCallsAfter304 = sourceMock.getHeightOrThrowCalls->Array.length
      await MockSource.waitHeightQuery(sourceMock, ~since=heightCallsAfter304)
      t.expect(
        sourceMock.pendingItemsQueries->Array.length,
        ~message="Should not fetch before the head is blockThrottle blocks past the fetched range",
      ).toBe(0)

      // The fifth block releases one fetch for all five.
      sourceMock.resolveGetHeightOrThrow(305)
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 301,
          toBlock: Unbounded,
          retryCount: 0,
          reply: Respond({items: [], latestFetchedBlockNumber: 305}),
        },
      ])
      await indexer.getBatchWritePromise()
    },
  )
})
