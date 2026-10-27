open Vitest

// The mock's replies are the test's only lever on the indexer's inputs.
// `expectItemsQueries` waits for the queries a test names instead of guessing
// how many ticks the indexer needs, and refuses to guess which query a reply
// belongs to.
let scenario = Scenario.make(
  ~configYaml=`
name: mock-answers
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

let sources: array<Scenario.sourceMock> = [
  {chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow]},
]

let reorgScenario = Scenario.make(
  ~configYaml=`
name: mock-answers-reorg
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

let reorgSources: array<Scenario.sourceMock> = [
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

let failureOf = async promise =>
  try {
    await promise
    None
  } catch {
  | JsExn(exn) => exn->JsExn.message
  }

describe("MockSource.expectItemsQueries", () => {
  scenario->Scenario.it("waits for the query it names and replies to it", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    mock.resolveGetHeightOrThrow(300)
    await mock.expectItemsQueries([
      {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), reply: Respond({items: []})},
    ])
    await indexer.getBatchWritePromise()
    await mock.expectItemsQueries([
      {
        fromBlock: 101,
        toBlock: Unbounded,
        reply: Respond({items: [], latestFetchedBlockNumber: 300}),
      },
    ])
    await indexer.getBatchWritePromise()
    t.expect(await indexer.metric("envio_progress_block")).toEqual([
      {value: "300", labels: dict{"chainId": "1"}},
    ])
  })

  // Two addresses on one contract with `maxAddrInPartition=1` give the chain two
  // partitions, so two item queries are pending at once.
  scenario->Scenario.it(
    "refuses a reply two pending queries could take, naming the field that tells them apart",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      t.expect(
        await failureOf(
          mock.expectItemsQueries([{reply: Respond({items: []})}, {reply: Respond({items: []})}]),
        ),
      ).toEqual(
        Some(`expectItemsQueries can reply to more than one pending query with entry #0 {reply: Respond(…)}, entry #1 {reply: Respond(…)}:
  {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}
  {partitionId: "1", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}
Give each query its own entry, told apart by partitionId:
  {partitionId: "0", reply: …}
  {partitionId: "1", reply: …}`),
      )
      await mock.expectItemsQueries([
        {partitionId: "0", reply: Respond({items: []})},
        {partitionId: "1", reply: Respond({items: []})},
      ])
      await indexer.getBatchWritePromise()
    },
  )

  // A predicate is free to assume what the entry's other fields guarantee.
  scenario->Scenario.it(
    "runs `where` only on the queries an entry's other fields match",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      let askedAbout = []
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          where: query => {
            askedAbout->Array.push(query.partitionId)
            true
          },
          reply: Respond({items: []}),
        },
        {partitionId: "1", reply: Respond({items: []})},
      ])
      await indexer.getBatchWritePromise()
      t.expect(askedAbout->Array.every(partitionId => partitionId === "0")).toBe(true)
    },
  )

  scenario->Scenario.it(
    "refuses to reply while a pending query is in no entry, then answers one left pending",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      t.expect(
        await failureOf(mock.expectItemsQueries([{partitionId: "1", reply: Respond({items: []})}])),
      ).toEqual(
        Some(`expectItemsQueries matched every entry, but these pending queries are in none:
  {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}
Reply to them in this list, or keep them pending:
  {partitionId: "0", reply: LeavePending}`),
      )

      await mock.expectItemsQueries([
        {partitionId: "1", reply: Respond({items: []})},
        {partitionId: "0", reply: LeavePending},
      ])
      t.expect(
        mock.pendingItemsQueries,
        ~message="partition 0 was checked and left pending",
      ).toEqual([{partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}])
      await mock.expectItemsQueries([{partitionId: "0", reply: Respond({items: []})}])
      await indexer.getBatchWritePromise()
    },
  )

  // The unlisted check runs once the list matches. A sibling's follow-up that
  // landed after it would move the failure to whichever later list ran first.
  scenario->Scenario.it(
    "sees every partition's follow-up before checking for unlisted queries",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      await mock.expectItemsQueries([
        {partitionId: "0", reply: Respond({items: [], latestFetchedBlockNumber: 50})},
        {partitionId: "1", reply: Respond({items: [], latestFetchedBlockNumber: 50})},
      ])
      t.expect(
        await failureOf(
          mock.expectItemsQueries([{partitionId: "0", fromBlock: 51, reply: LeavePending}]),
        ),
      ).toEqual(
        Some(`expectItemsQueries matched every entry, but these pending queries are in none:
  {partitionId: "1", fromBlock: 51, toBlock: Bounded(100), retryCount: 0}
Reply to them in this list, or keep them pending:
  {partitionId: "1", reply: LeavePending}`),
      )
      await mock.respondEmptyUpTo(300)
      await indexer.getBatchWritePromise()
    },
  )

  scenario->Scenario.it("times out saying why each entry is unmatched", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    t.expect(
      await failureOf(
        mock.expectItemsQueries([{partitionId: "0", toBlock: Unbounded, reply: LeavePending}]),
      ),
      ~message="nothing is pending before the chain knows the head",
    ).toEqual(
      Some(`expectItemsQueries timed out. Expected:
  #0 {partitionId: "0", toBlock: Unbounded, reply: LeavePending} (matches no pending query)
Pending:
  none`),
    )

    mock.resolveGetHeightOrThrow(300)
    t.expect(
      await failureOf(
        mock.expectItemsQueries([
          {fromBlock: 1, reply: Respond({items: []})},
          {partitionId: "0", reply: LeavePending},
        ]),
      ),
      ~message="a single pending query can't be both replied to and left pending",
    ).toEqual(
      Some(`expectItemsQueries timed out. Expected:
  #0 {fromBlock: 1, reply: Respond(…)}
  #1 {partitionId: "0", reply: LeavePending} (every query it matches is taken by a reply)
Pending:
  {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}`),
    )
    await mock.respondEmptyUpTo(300)
    await indexer.getBatchWritePromise()
  })

  // A real source never reports having fetched past the range it was asked for,
  // so a reply that does describes a source that doesn't exist.
  scenario->Scenario.it("refuses a reply past the query's toBlock", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    mock.resolveGetHeightOrThrow(300)
    t.expect(
      await failureOf(
        mock.expectItemsQueries([
          {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 300})},
        ]),
      ),
    ).toEqual(
      Some(`expectItemsQueries can't reply latestFetchedBlockNumber 300 to {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}: a source never fetches past the toBlock it was asked for`),
    )
    mock.drainPendingItemsQueries()
    await indexer.getBatchWritePromise()
  })

  scenario->Scenario.it("refuses an item outside the range the reply covers", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    mock.resolveGetHeightOrThrow(300)
    t.expect(
      await failureOf(
        mock.expectItemsQueries([
          {fromBlock: 1, reply: Respond({items: [{blockNumber: 250, logIndex: 0}]})},
        ]),
      ),
    ).toEqual(
      Some(`expectItemsQueries can't reply an item at block 250 to {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}: a source only returns items between the query's fromBlock and the latestFetchedBlockNumber it replies (100)`),
    )
    await mock.respondEmptyUpTo(300)
    await indexer.getBatchWritePromise()
  })

  // What vitest prints for a pending query in a failed whole-value assert.
  scenario->Scenario.it("serializes a pending query the way a test writes it", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    mock.resolveGetHeightOrThrow(300)
    await mock.expectItemsQueries([{reply: LeavePending}])
    t.expect(mock.pendingItemsQueries->JSON.stringifyAny).toEqual(
      Some(`[{"partitionId":"0","fromBlock":1,"toBlock":100,"retryCount":0}]`),
    )
    await mock.respondEmptyUpTo(300)
    await indexer.getBatchWritePromise()
  })

  scenario->Scenario.it("fails a query, and waits for the chain to retry it", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    mock.resolveGetHeightOrThrow(300)
    await mock.expectItemsQueries([
      {fromBlock: 1, reply: Fail(Source.SourceBehindHead({blockNumber: 50, requestStats: []}))},
    ])
    // The retry comes after a backoff; the wait covers it without knowing how long.
    await mock.expectItemsQueries([{retryCount: 1, reply: LeavePending}])
    t.expect(mock.pendingItemsQueries).toEqual([
      {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 1},
    ])
    await mock.respondEmptyUpTo(300)
    await indexer.getBatchWritePromise()
  })

  // One partition reaching the block doesn't carry a partition still behind it.
  scenario->Scenario.it(
    "fetches every partition up to the block, not just the first to reach it",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      await mock.expectItemsQueries([
        {partitionId: "0", reply: Respond({items: []})},
        {partitionId: "1", reply: Respond({items: [], latestFetchedBlockNumber: 50})},
      ])
      await indexer.getBatchWritePromise()
      await mock.respondEmptyUpTo(300)
      await indexer.getBatchWritePromise()
      t.expect((await indexer.metric("envio_progress_block"), mock.pendingItemsQueries)).toEqual((
        [{value: "300", labels: dict{"chainId": "1"}}],
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "fetches empty ranges up to a block, one realistic wave at a time",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      await mock.respondEmptyUpTo(300)
      await indexer.getBatchWritePromise()
      t.expect((await indexer.metric("envio_progress_block"), mock.pendingItemsQueries)).toEqual((
        [{value: "300", labels: dict{"chainId": "1"}}],
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "builds a reply from the query it matched",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      let halfway = MockSource.RespondWith(
        query => {items: [], latestFetchedBlockNumber: query.fromBlock + 49},
      )
      await mock.expectItemsQueries([
        {partitionId: "0", reply: halfway},
        {partitionId: "1", reply: halfway},
      ])
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 51, reply: LeavePending},
        {partitionId: "1", fromBlock: 51, reply: LeavePending},
      ])
      t.expect(mock.pendingItemsQueries->Array.map(query => query.fromBlock)).toEqual([51, 51])
      await mock.respondEmptyUpTo(300)
      await indexer.getBatchWritePromise()
    },
  )

  // A test that fakes the clock still gets the timeout message instead of a
  // suite-level hang, so the deadline can't run on the faked setTimeout.
  scenario->Scenario.it("times out on the real clock while timers are faked", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    mock.resolveGetHeightOrThrow(300)
    await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
    Vi.useFakeTimers()
    let failure = await failureOf(mock.expectItemsQueries([{fromBlock: 2, reply: LeavePending}]))
    Vi.useRealTimers()
    t.expect(failure).toEqual(
      Some(`expectItemsQueries timed out. Expected:
  #0 {fromBlock: 2, reply: LeavePending} (matches no pending query)
Pending:
  {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}`),
    )
    await mock.respondEmptyUpTo(300)
    await indexer.getBatchWritePromise()
  })

  scenario->Scenario.it("voids the stopped indexer's pending query on restart", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    mock.resolveGetHeightOrThrow(300)
    await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
    let stale = mock.pendingItemsQueries->Array.copy

    let restarted = await indexer.restart()
    mock.resolveGetHeightOrThrow(300)
    // Without the drop the stale query is still pending with the same payload,
    // and this reply can't tell which of the two it is for.
    await mock.expectItemsQueries([{fromBlock: 1, reply: Respond({items: []})}])
    await restarted.getBatchWritePromise()
    t.expect(
      mock.pendingItemsQueries->Array.some(query => stale->Array.includes(query)),
      ~message="the stopped indexer's query is gone",
    ).toBe(false)
  })
})

describe("MockSource.expectHeightCalls", () => {
  scenario->Scenario.it("waits for the chain's first height call", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    await mock.expectHeightCalls(1)
    t.expect(await failureOf(mock.expectHeightCalls(0))).toEqual(
      Some("expectHeightCalls expected 0 height calls, but the source has taken 1"),
    )
    mock.resolveGetHeightOrThrow(300)
    await mock.respondEmptyUpTo(300)
    await indexer.getBatchWritePromise()
  })

  scenario->Scenario.it("times out naming the count it waited for", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    await mock.expectHeightCalls(1)
    t.expect(await failureOf(mock.expectHeightCalls(2))).toEqual(
      Some("expectHeightCalls timed out waiting for 2 height calls; the source has taken 1"),
    )
    mock.resolveGetHeightOrThrow(300)
    await mock.respondEmptyUpTo(300)
    await indexer.getBatchWritePromise()
  })
})

describe("MockSource.expectBlockHashLookup", () => {
  reorgScenario->Scenario.it(
    "waits for the rollback's lookup and replies with the hashes it gives",
    ~sources=reorgSources,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      await reorgAtHead(~indexer, ~mock)
      await mock.expectBlockHashLookup({
        blockNumbers: [200],
        reply: [{blockNumber: 200, blockHash: "0x200", blockTimestamp: 200}],
      })
      await mock.expectItemsQueries([
        {
          fromBlock: 201,
          toBlock: Unbounded,
          reply: Respond({items: [], latestFetchedBlockNumber: 301}),
        },
      ])
      await indexer.getBatchWritePromise()
      t.expect(await indexer.metric("envio_progress_block")).toEqual([
        {value: "301", labels: dict{"chainId": "1"}},
      ])
    },
  )

  reorgScenario->Scenario.it(
    "refuses to reply to a lookup of other blocks, naming the one asked",
    ~sources=reorgSources,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      await reorgAtHead(~indexer, ~mock)
      t.expect(
        await failureOf(
          mock.expectBlockHashLookup({
            blockNumbers: [100],
            reply: [{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}],
          }),
        ),
      ).toEqual(
        Some(`expectBlockHashLookup expected a lookup of [100], but the pending lookup asks for [200]`),
      )
      await mock.expectBlockHashLookup({
        blockNumbers: [200],
        reply: [{blockNumber: 200, blockHash: "0x200", blockTimestamp: 200}],
      })
      await mock.expectItemsQueries([
        {fromBlock: 201, reply: Respond({items: [], latestFetchedBlockNumber: 301})},
      ])
      await indexer.getBatchWritePromise()
    },
  )

  reorgScenario->Scenario.it(
    "times out naming the lookup it waited for",
    ~sources=reorgSources,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      t.expect(
        await failureOf(
          mock.expectBlockHashLookup({
            blockNumbers: [200],
            reply: [{blockNumber: 200, blockHash: "0x200", blockTimestamp: 200}],
          }),
        ),
      ).toEqual(
        Some(`expectBlockHashLookup timed out waiting for a lookup of [200]. No lookup is pending.`),
      )
      await mock.respondEmptyUpTo(300)
      await indexer.getBatchWritePromise()
    },
  )
})

// A test that starts expecting while a burst is still landing has to see the
// whole burst, not match whichever call happened to arrive first.
describe("MockSource waits for a burst to fully arrive", () => {
  Async.it("matches a fan-out of item queries only once all of it is pending", async t => {
    let mock = MockSource.make([#getItemsOrThrow])
    let query = partitionId =>
      mock.source.getItemsOrThrow(
        ~fromBlock=0,
        ~toBlock=None,
        ~addressSet=TestAddresses.setOf([]),
        ~includeAllBlocks=false,
        ~knownHeight=100,
        ~partitionId,
        ~selection={dependsOnAddresses: false, onEventRegistrations: []},
        ~itemsTarget=None,
        ~retry=0,
        ~logger=Logger.makeInMemory(),
      )->ignore
    query("0")
    let expectation = mock.expectItemsQueries([{reply: Respond({items: []})}])
    query("1")
    t.expect(await failureOf(expectation)).toEqual(
      Some(`expectItemsQueries can reply to more than one pending query with entry #0 {reply: Respond(…)}:
  {partitionId: "0", fromBlock: 0, toBlock: Unbounded, retryCount: 0}
  {partitionId: "1", fromBlock: 0, toBlock: Unbounded, retryCount: 0}
Give each query its own entry, told apart by partitionId:
  {partitionId: "0", reply: …}
  {partitionId: "1", reply: …}`),
    )
    mock.drainPendingItemsQueries()
  })

  Async.it("counts height calls only once all of them have arrived", async t => {
    let mock = MockSource.make([#getHeightOrThrow])
    let _ = mock.source.getHeightOrThrow()
    let expectation = mock.expectHeightCalls(1)
    let _ = mock.source.getHeightOrThrow()
    t.expect(await failureOf(expectation)).toEqual(
      Some("expectHeightCalls expected 1 height calls, but the source has taken 2"),
    )
  })

  Async.it("answers a block-hash lookup only once all of them have arrived", async t => {
    let mock = MockSource.make([#getBlockHashes])
    let lookUp = blockNumbers =>
      mock.source.getBlockHashes(~blockNumbers, ~logger=Logger.makeInMemory())->ignore
    lookUp([10])
    let expectation = mock.expectBlockHashLookup({blockNumbers: [10], reply: []})
    lookUp([20])
    t.expect(await failureOf(expectation)).toEqual(
      Some("expectBlockHashLookup can't tell which of 2 pending lookups to answer: [10], [20]"),
    )
  })
})
