open Vitest

// The block hashes a rollback looks up to find how deep a reorg went: how the
// lookup recovers from what the source reports back.
let scenario = Scenario.make(
  ~configYaml=`
name: block-hash-lookup
rollback_on_reorg: true
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
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

let sources: array<Scenario.sourceMock> = [
  {chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
]

// Stops at block 200 on the way to the head, so the rollback has a stored block
// inside the reorg threshold to look up, then reports block 300 re-orged.
let reorgAtHead = async (~indexer: IndexerRunner.t, ~mock: MockSource.t) => {
  mock.resolveGetHeightOrThrow(300)
  await mock.expectItemsQueries([
    {fromBlock: 1, toBlock: Bounded(100), reply: Respond({items: []})},
  ])
  await indexer.getBatchWritePromise()
  await mock.expectItemsQueries([
    {fromBlock: 101, reply: Respond({items: [], latestFetchedBlockNumber: 200})},
  ])
  await mock.expectItemsQueries([
    {fromBlock: 201, reply: Respond({items: [], latestFetchedBlockNumber: 300})},
  ])
  await indexer.getBatchWritePromise()
  mock.resolveGetHeightOrThrow(301)
  await mock.expectItemsQueries([
    {
      fromBlock: 301,
      reply: Respond({
        items: [],
        latestFetchedBlockNumber: 301,
        prevRangeLastBlock: {blockNumber: 300, blockHash: "0x300a"},
      }),
    },
  ])
}

let lookups = (mock: MockSource.t) => mock.getBlockHashesCalls->Array.length

let awaitLookup = (mock, ~count) =>
  Scenario.waitUntil(
    () => mock->lookups >= count,
    ~message=`block-hash lookup #${count->Int.toString}`,
  )

let block200: array<BlockStore.inputBlock> = [
  {blockNumber: 200, blockHash: "0x200", blockTimestamp: 200},
]

// The rollback resolved at the lookup's answer, and the chain refetches past it.
let finishRollback = async (mock: MockSource.t) => {
  await mock.expectBlockHashLookup({blockNumbers: [200], reply: block200})
  await mock.expectItemsQueries([{fromBlock: 201, reply: LeavePending}])
}

describe("Block-hash lookups", () => {
  scenario->Scenario.it("Waits out a rate limit and retries the lookup", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    await reorgAtHead(~indexer, ~mock)
    await mock->awaitLookup(~count=1)
    mock.failGetBlockHashes(Source.RateLimited({resetMs: 50, requestStats: []}))
    await indexer.advanceTime(50)
    await mock->finishRollback

    let rateLimitedSeconds =
      (await indexer.metric("envio_indexing_source_rate_limited_seconds"))->Array.map(
        ({value}) => value->Float.fromString->Option.getOr(0.),
      )
    t.expect((
      indexer.allLogsAsJson()->Array.filterMap(
        line =>
          switch (line->Dict.get("msg"), line->Dict.get("waitMs")) {
          | (Some(String(msg)), Some(waitMs)) if msg->String.includes("rate-limited") =>
            Some(waitMs)
          | _ => None
          },
      ),
      // The lookup's wait counts towards the chain's rate-limited time too.
      rateLimitedSeconds,
    )).toEqual(([Number(50.)], [0.05]))
  })

  scenario->Scenario.it(
    "Drops the source's orphaned state before retrying a lookup that contradicted itself",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      await reorgAtHead(~indexer, ~mock)
      await mock->awaitLookup(~count=1)
      let reorgsBefore = mock.reorgCallCount()
      mock.resolveGetBlockHashes([
        {blockNumber: 200, blockHash: "0x200", blockTimestamp: 200},
        {blockNumber: 200, blockHash: "0x201", blockTimestamp: 200},
      ])
      await indexer.advanceTime(100)
      await mock->finishRollback
      t.expect((mock->lookups, mock.reorgCallCount() - reorgsBefore)).toEqual((2, 1))
    },
  )

  scenario->Scenario.it("Retries a lookup that left out a requested block", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    await reorgAtHead(~indexer, ~mock)
    await mock->awaitLookup(~count=1)
    mock.resolveGetBlockHashes([])
    await indexer.advanceTime(100)
    await mock->finishRollback
    t.expect(mock->lookups).toEqual(2)
  })

  scenario->Scenario.it("Backs off and retries a lookup that failed", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    await reorgAtHead(~indexer, ~mock)
    await mock->awaitLookup(~count=1)
    mock.failGetBlockHashes(JsError.make("connection reset")->(Utils.magic: JsError.t => exn))
    await indexer.advanceTime(100)
    await mock->finishRollback
    t.expect(
      indexer.allLogsAsJson()->Array.filterMap(
        line =>
          switch (line->Dict.get("msg"), line->Dict.get("backOffMilliseconds")) {
          | (Some(String("Failed to fetch block hashes. Retrying.")), Some(ms)) => Some(ms)
          | _ => None
          },
      ),
    ).toEqual([Number(100.)])
  })

  scenario->Scenario.it("Counts a lookup that failed behind the head once", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    await reorgAtHead(~indexer, ~mock)
    await mock->awaitLookup(~count=1)
    // A native source reports the request both on the response and on the
    // failure it carries, so a retry can still count it.
    let requestStats = [{Source.method: "getBlockHashes", seconds: 0.1}]
    mock.failGetBlockHashes(
      Source.SourceBehindHead({blockNumber: 200, requestStats}),
      ~requestStats,
    )
    await indexer.advanceTime(100)
    await mock->finishRollback
    t.expect(
      (await indexer.metric("envio_source_request_total"))->Array.filterMap(
        ({value, labels}: IndexerRunner.metric) =>
          labels->Dict.get("method") == Some("getBlockHashes") ? Some(value) : None,
      ),
    ).toEqual(["1"])
  })
})
