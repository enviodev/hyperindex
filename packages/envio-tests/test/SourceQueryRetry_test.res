open Vitest

// How a chain's items query recovers from what a single source reports back:
// the backoff, the logs an operator reads, and what the metrics count.
let scenario = Scenario.make(
  ~configYaml=`
name: source-query-retry
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
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
  ~virtualTime=true,
)

let withBackoff = Source.GetItemsError(
  FailedGettingItems({
    requestStats: [],
    attemptedToBlock: 100,
    retry: WithBackoff({message: "Failed getting data for the block range.", backoffMillis: 0}),
  }),
)

let behindHead = MockSource.Fail(Source.SourceBehindHead({blockNumber: 1, requestStats: []}))

// The query retry lines carry the backoff they waited, which is the schedule
// an operator reads in the logs.
let retryLines = (indexer: IndexerRunner.t) =>
  indexer.allLogsAsJson()->Array.filter(line =>
    line->Dict.get("backOffMilliseconds")->Option.isSome
  )

let backoffs = (indexer: IndexerRunner.t) =>
  indexer
  ->retryLines
  ->Array.filterMap(line =>
    switch line->Dict.get("backOffMilliseconds") {
    | Some(Number(ms)) => Some(ms)
    | _ => None
    }
  )

let pick = (line: dict<JSON.t>, keys) =>
  keys
  ->Array.filterMap(key => line->Dict.get(key)->Option.map(value => (key, value)))
  ->Dict.fromArray

let requestMetrics = async (indexer: IndexerRunner.t, name) =>
  (await indexer.metric(name))->Array.filterMap(({value, labels}: IndexerRunner.metric) =>
    switch labels->Dict.get("method") {
    | Some("getLogs") => Some(value)
    | _ => None
    }
  )

describe("Items query retries on a single source", () => {
  scenario->Scenario.it(
    "Retries a source that hasn't reached the queried block yet",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, retryCount: 0, reply: behindHead}])
      await indexer.advanceTime(100)
      await sync.expectItemsQueries([
        {fromBlock: 1, retryCount: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      t.expect(sync.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Drops the source's orphaned state before retrying an inconsistent response",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 9})},
      ])
      let reorgsBefore = sync.reorgCallCount()
      await sync.expectItemsQueries([
        {
          fromBlock: 10,
          retryCount: 0,
          // Block 9 twice with different hashes: once as the range's parent
          // guard and once as the reported latest block.
          reply: Respond({items: [], latestFetchedBlockNumber: 9, latestFetchedBlockHash: "0x0a"}),
        },
      ])
      await indexer.advanceTime(100)
      await sync.expectItemsQueries([{fromBlock: 10, retryCount: 1, reply: LeavePending}])
      t.expect(sync.reorgCallCount() - reorgsBefore).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Tells the user a source behind the head is catching up, not failing",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      // Retries 0 to 12: the quiet window, then the first attempt past it.
      let early = await Scenario.failThroughBackoff(
        ~indexer,
        ~source=sync,
        ~reply=behindHead,
        ~waits=[100, 200, 400, 800, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000],
      )
      await sync.expectItemsQueries([{retryCount: 13, reply: LeavePending}])

      let keys = [
        "level",
        "msg",
        "logType",
        "partitionId",
        "source",
        "fromBlock",
        "addresses",
        "retry",
        "backOffMilliseconds",
      ]
      let lines = indexer->retryLines
      t.expect((
        early,
        lines->Array.get(0)->Option.map(pick(_, keys)),
        lines->Array.get(12)->Option.map(pick(_, keys)),
      )).toEqual((
        [],
        Some(
          JSON.parseOrThrow(`{
            "level": "trace",
            "msg": "MockSource hasn't reached block 1 on all of its servers yet. This is normal near the latest block and resolves by itself - retrying shortly.",
            "logType": "Block Range Query",
            "partitionId": "0",
            "source": "MockSource",
            "fromBlock": 1,
            "addresses": 1,
            "retry": 0,
            "backOffMilliseconds": 100
          }`)->(Utils.magic: JSON.t => dict<JSON.t>),
        ),
        Some(
          JSON.parseOrThrow(`{
            "level": "warn",
            "msg": "MockSource is still catching up to block 1. This is a delay on the provider's side; indexing will continue automatically, using another data source if one is configured.",
            "logType": "Block Range Query",
            "partitionId": "0",
            "source": "MockSource",
            "fromBlock": 1,
            "addresses": 1,
            "retry": 12,
            "backOffMilliseconds": 1000
          }`)->(Utils.magic: JSON.t => dict<JSON.t>),
        ),
      ))
    },
  )

  scenario->Scenario.it(
    "Backs off further once a source stays behind the head past the window and has no alternative",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      // What the retries actually wait is what they log.
      let early = await Scenario.failThroughBackoff(
        ~indexer,
        ~source=sync,
        ~reply=behindHead,
        ~waits=[
          100,
          200,
          400,
          800,
          1000,
          1000,
          1000,
          1000,
          1000,
          1000,
          1000,
          1000,
          1000,
          2000,
          4000,
          8000,
        ],
      )
      await sync.expectItemsQueries([{retryCount: 16, reply: LeavePending}])

      // The logged schedule: the window keeps attempts a second apart at most;
      // past it, a source that is still behind is polled less and less often.
      t.expect((early, indexer->backoffs)).toEqual((
        [],
        [
          100.,
          200.,
          400.,
          800.,
          1000.,
          1000.,
          1000.,
          1000.,
          1000.,
          1000.,
          1000.,
          1000.,
          1000.,
          2000.,
          4000.,
          8000.,
        ],
      ))
    },
  )

  scenario->Scenario.it(
    "Counts the requests a failed getItems still made",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      // The native client reports the timings of the requests it made before
      // giving up, so a source failing under load still shows up in its metrics.
      await sync.expectItemsQueries([
        {
          retryCount: 0,
          reply: Fail(
            Source.SourceBehindHead({
              blockNumber: 1,
              requestStats: [{Source.method: "getLogs", seconds: 0.5}],
            }),
          ),
        },
      ])
      await indexer.advanceTime(100)
      await sync.expectItemsQueries([{retryCount: 1, reply: LeavePending}])

      t.expect((
        await indexer->requestMetrics("envio_source_request_total"),
        await indexer->requestMetrics("envio_source_request_seconds_total"),
      )).toEqual((["1"], ["0.5"]))
    },
  )

  scenario->Scenario.it(
    "Sums the blocks a source returned and counts its empty responses",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 50,
            requestStats: [{Source.method: "getLogs", seconds: 0.5, responseBlocks: 3}],
          }),
        },
      ])
      // A range the source scanned and found nothing in: it still costs a
      // request, and under a per-block price it is the one that costs nothing.
      await sync.expectItemsQueries([
        {
          fromBlock: 51,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 100,
            requestStats: [{Source.method: "getLogs", seconds: 0.25, responseBlocks: 0}],
          }),
        },
      ])

      t.expect((
        await indexer->requestMetrics("envio_source_request_total"),
        await indexer->requestMetrics("envio_source_response_blocks_total"),
        await indexer->requestMetrics("envio_source_response_empty_total"),
      )).toEqual((["2"], ["3"], ["1"]))
    },
  )

  let stopped = []
  scenario->Scenario.it(
    "Stops the indexer with an error the source doesn't classify",
    ~sources=[{chain: 1337}],
    ~onError=errHandler => stopped->Array.push(errHandler.exn->Utils.prettifyExn)->ignore,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([
        {reply: Fail(JsError.make("Something went wrong")->(Utils.magic: JsError.t => exn))},
      ])
      await Scenario.waitUntil(() => stopped->Array.length > 0, ~message="the indexer to stop")
      // Nothing retries it: the query is never asked again.
      await indexer.advanceTime(10)
      t.expect((
        stopped->Array.map(exn => (exn->(Utils.magic: exn => {"message": string}))["message"]),
        sync.pendingItemsQueries,
      )).toEqual((["Something went wrong"], []))
    },
  )

  scenario->Scenario.it(
    "Immediately retries with the suggested toBlock, on the same source",
    // A second source the retry could have moved to, and must not.
    ~sources=[{chain: 1337}, {chain: 1337}],
    // No time passes here, so the retry arriving at all proves it didn't wait.
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let other = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([
        {
          fromBlock: 1,
          toBlock: Unbounded,
          retryCount: 0,
          reply: Fail(
            Source.GetItemsError(
              FailedGettingItems({
                requestStats: [],
                attemptedToBlock: 100,
                retry: WithSuggestedToBlock({toBlock: 10}),
              }),
            ),
          ),
        },
      ])
      await sync.expectItemsQueries([
        {
          fromBlock: 1,
          // The next attempt asks a strictly smaller question, so its schedule
          // starts over.
          toBlock: Bounded(10),
          retryCount: 0,
          reply: LeavePending,
        },
      ])
      t.expect((sync.pendingItemsQueries->Array.length, other.pendingItemsQueries)).toEqual((1, []))
    },
  )

  scenario->Scenario.it(
    "Waits and counts a suggested toBlock that doesn't narrow the attempted range",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      // The provider reports a cap it doesn't apply: what it suggests is the
      // range it just refused, so retrying that suggestion makes no progress.
      await sync.expectItemsQueries([
        {
          retryCount: 0,
          reply: Fail(
            Source.GetItemsError(
              FailedGettingItems({
                requestStats: [],
                attemptedToBlock: 100,
                retry: WithSuggestedToBlock({toBlock: 100}),
              }),
            ),
          ),
        },
      ])
      // The suggestion isn't applied, and the attempt counts towards the
      // failover schedule instead of restarting it.
      await indexer.advanceTime(100)
      await sync.expectItemsQueries([
        {fromBlock: 1, toBlock: Unbounded, retryCount: 1, reply: LeavePending},
      ])
      t.expect(indexer->backoffs).toEqual([100.])
    },
  )

  scenario->Scenario.it(
    "Keeps retrying a single source that fails with a backoff",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      // Past the point a failover would be tried, with nowhere to fail over to.
      for retryCount in 0 to 3 {
        await sync.expectItemsQueries([{retryCount, reply: Fail(withBackoff)}])
      }
      await sync.expectItemsQueries([{retryCount: 4, reply: LeavePending}])
      t.expect(sync.pendingItemsQueries->Array.length).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Reports a query every source has failed for minutes as an error",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      // Every attempt up to and including the one that crosses the threshold.
      for retryCount in 0 to 13 {
        await sync.expectItemsQueries([{retryCount, reply: Fail(withBackoff)}])
      }
      await sync.expectItemsQueries([{retryCount: 14, reply: LeavePending}])

      t.expect(
        indexer.allLogsAsJson()->Array.filterMap(
          line =>
            switch (line->Dict.get("level"), line->Dict.get("msg")) {
            | (Some(String("error")), Some(String(msg))) => Some(msg)
            | _ => None
            },
        ),
      ).toEqual([
        "Failed getting data for the block range. No source available to this chain has served this query on any attempt since, so indexing has stopped making progress.",
      ])
    },
  )
})
