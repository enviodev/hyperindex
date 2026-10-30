open Vitest

// Time a chain spent waiting out rate limits, as the metric reports it.
let scenario = Scenario.make(
  ~configYaml=`
name: rate-limit
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
        address:
          - "0x0000000000000000000000000000000000000001"
          - "0x0000000000000000000000000000000000000002"
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

let rateLimited = resetMs => MockSource.Fail(Source.RateLimited({resetMs, requestStats: []}))

let rateLimitedSeconds = async (indexer: IndexerRunner.t) =>
  (await indexer.metric("envio_indexing_source_rate_limited_seconds"))->Array.map((
    {value, labels}: IndexerRunner.metric,
  ) => (labels->Dict.get("chainId"), value->Float.fromString))

describe("Rate-limit time", () => {
  scenario->Scenario.it(
    "Reports no rate-limited time for a chain that was never throttled",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(await indexer->rateLimitedSeconds).toEqual([(Some("1"), Some(0.))])
    },
  )

  scenario->Scenario.it(
    "Counts the time a query waited out a rate limit",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, retryCount: 0, reply: rateLimited(200)}])
      await indexer.advanceTime(200)
      await mock.expectItemsQueries([{fromBlock: 1, retryCount: 1, reply: LeavePending}])
      t.expect(await indexer->rateLimitedSeconds).toEqual([(Some("1"), Some(0.2))])
    },
  )

  scenario->Scenario.it(
    "Counts rate limits that overlap in time only once",
    ~sources=[{chain: 1}],
    // One partition per address, so two queries are throttled at once.
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([
        {partitionId: "0", retryCount: 0, reply: rateLimited(300)},
        {partitionId: "1", retryCount: 0, reply: rateLimited(300)},
      ])
      await indexer.advanceTime(300)
      await mock.expectItemsQueries([
        {partitionId: "0", retryCount: 1, reply: LeavePending},
        {partitionId: "1", retryCount: 1, reply: LeavePending},
      ])
      // Two 300ms waits side by side are 300ms of the chain being throttled.
      t.expect(await indexer->rateLimitedSeconds).toEqual([(Some("1"), Some(0.3))])
    },
  )
})
