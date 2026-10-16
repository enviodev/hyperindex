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
        {partitionId: "0", reply: Respond({items: [], latestFetchedBlockNumber: 300})},
        {partitionId: "1", reply: Respond({items: [], latestFetchedBlockNumber: 300})},
      ])
      await indexer.getBatchWritePromise()
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
        await failureOf(
          mock.expectItemsQueries([
            {partitionId: "1", reply: Respond({items: [], latestFetchedBlockNumber: 300})},
          ]),
        ),
      ).toEqual(
        Some(`expectItemsQueries matched every entry, but these pending queries are in none:
  {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}
Reply to them in this list, or keep them pending:
  {partitionId: "0", reply: LeavePending}`),
      )

      await mock.expectItemsQueries([
        {partitionId: "1", reply: Respond({items: [], latestFetchedBlockNumber: 300})},
        {partitionId: "0", reply: LeavePending},
      ])
      t.expect(
        mock.pendingItemsQueries,
        ~message="partition 0 was checked and left pending",
      ).toEqual([{partitionId: "0", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}])
      await mock.expectItemsQueries([
        {partitionId: "0", reply: Respond({items: [], latestFetchedBlockNumber: 300})},
      ])
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
      mock.drainPendingItemsQueries(~latestFetchedBlockNumber=300)
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
    mock.drainPendingItemsQueries(~latestFetchedBlockNumber=300)
    await indexer.getBatchWritePromise()
  })

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
    mock.drainPendingItemsQueries(~latestFetchedBlockNumber=300)
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
    await mock.expectItemsQueries([
      {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 300})},
    ])
    await restarted.getBatchWritePromise()
    t.expect(
      mock.pendingItemsQueries->Array.some(query => stale->Array.includes(query)),
      ~message="the stopped indexer's query is gone",
    ).toBe(false)
  })
})
