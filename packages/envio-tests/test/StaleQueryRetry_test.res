open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: stale-query-retry
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 199
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer()
  - id: 2
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 199
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.chainId}@\${event.block.number}\` });
});
`,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let failWithBackoff = MockSource.Fail(
  Source.GetItemsError(
    FailedGettingItems({
      requestStats: [],
      attemptedToBlock: 301,
      retry: WithBackoff({
        message: "Failed getting data for the block range.",
        backoffMillis: 5000,
      }),
    }),
  ),
)

describe("A query in flight when a rollback lands", () => {
  scenario->Scenario.it(
    "stops retrying once the rollback makes it stale",
    ~sources=[{chain: 1, methods}, {chain: 2, methods}],
    async (~t, ~indexer, ~source) => {
      let first = source(1)
      let second = source(2)
      first.resolveGetHeightOrThrow(300)
      second.resolveGetHeightOrThrow(300)
      // A chain enters its reorg threshold only once every chain reaches its own.
      await first.respondEmptyUpTo(100)
      await second.respondEmptyUpTo(100)
      await first.respondEmptyUpTo(300)
      await second.respondEmptyUpTo(300)

      second.resolveGetHeightOrThrow(301)
      await second.expectItemsQueries([{fromBlock: 301, retryCount: 0, reply: failWithBackoff}])

      first.resolveGetHeightOrThrow(301)
      await first.expectItemsQueries([
        {
          fromBlock: 301,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 301,
            prevRangeLastBlock: {blockNumber: 300, blockHash: "0x300a"},
          }),
        },
      ])
      await Scenario.driveRollback(~source=first, ~validUpTo=100)
      await indexer.waitUntilIdle()

      await indexer.advanceTime(5000)
      await indexer.waitUntilIdle()
      t.expect(
        second.pendingItemsQueries->Array.map(({fromBlock, retryCount}) => (fromBlock, retryCount)),
        ~message="only the query planned after the rollback is left to fetch",
      ).toEqual([(300, 0)])
    },
  )
})
