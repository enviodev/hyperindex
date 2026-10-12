open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: intercept-answers
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

describe("MockSource.interceptGetItemsCalls", () => {
  scenario->Scenario.it("answers the one call the chain makes", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    mock.resolveGetHeightOrThrow(300)
    await mock->MockSource.interceptGetItemsCalls([
      {fromBlock: 1, toBlock: Some(100), p: "0", resolve: {items: []}},
    ])
    await indexer.getBatchWritePromise()
    await mock->MockSource.interceptGetItemsCalls([
      {fromBlock: 101, toBlock: None, resolve: {items: [], latestFetchedBlockNumber: 300}},
    ])
    await indexer.getBatchWritePromise()
    t.expect(await indexer.metric("envio_progress_block")).toEqual([
      {value: "300", labels: dict{"chainId": "1"}},
    ])
  })

  scenario->Scenario.it(
    "refuses a spec two partitions could take, naming the field that tells them apart",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      t.expect(
        await failureOf(
          mock->MockSource.interceptGetItemsCalls([{resolve: {items: []}}, {resolve: {items: []}}]),
        ),
      ).toEqual(
        Some(`interceptGetItemsCalls can pair spec #0 {}, spec #1 {} with more than one pending call:
  {p: "0", fromBlock: 1, toBlock: Some(100), retry: 0}
  {p: "1", fromBlock: 1, toBlock: Some(100), retry: 0}
Give each call its own spec, told apart by p:
  {p: "0"}
  {p: "1"}`),
      )
      await mock->MockSource.interceptGetItemsCalls([
        {p: "0", resolve: {items: [], latestFetchedBlockNumber: 300}},
        {p: "1", resolve: {items: [], latestFetchedBlockNumber: 300}},
      ])
      await indexer.getBatchWritePromise()
    },
  )

  scenario->Scenario.it(
    "refuses to complete while a pending sibling is in no spec",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      t.expect(
        await failureOf(
          mock->MockSource.interceptGetItemsCalls([
            {p: "1", resolve: {items: [], latestFetchedBlockNumber: 300}},
          ]),
        ),
      ).toEqual(
        Some(`interceptGetItemsCalls matched every spec, but these pending calls are in no spec:
  {p: "0", fromBlock: 1, toBlock: Some(100), retry: 0}
Answer them in this list, or list them without an answer to leave them in flight:
  {p: "0"}`),
      )

      await mock->MockSource.interceptGetItemsCalls([
        {p: "1", resolve: {items: [], latestFetchedBlockNumber: 300}},
        {p: "0"},
      ])
      t.expect(
        mock.getItemsOrThrowCalls->Array.map(call => call.payload["p"]),
        ~message="p0 was checked and left in flight",
      ).toEqual(["0"])
      await mock->MockSource.interceptGetItemsCalls([
        {p: "0", resolve: {items: [], latestFetchedBlockNumber: 300}},
      ])
      await indexer.getBatchWritePromise()
    },
  )

  // The unclaimed check runs once the wave matches. A sibling's follow-up that
  // landed after it would move the failure to whichever later list ran first.
  scenario->Scenario.it(
    "sees every partition's follow-up before checking for unclaimed calls",
    ~sources,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      await mock->MockSource.interceptGetItemsCalls([
        {p: "0", resolve: {items: [], latestFetchedBlockNumber: 50}},
        {p: "1", resolve: {items: [], latestFetchedBlockNumber: 50}},
      ])
      t.expect(
        await failureOf(mock->MockSource.interceptGetItemsCalls([{p: "0", fromBlock: 51}])),
      ).toEqual(
        Some(`interceptGetItemsCalls matched every spec, but these pending calls are in no spec:
  {p: "1", fromBlock: 51, toBlock: Some(100), retry: 0}
Answer them in this list, or list them without an answer to leave them in flight:
  {p: "1"}`),
      )
      mock.drainItemsQueries(~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
    },
  )

  scenario->Scenario.it("times out naming what it waited for", ~sources, async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let mock = source(1)
    t.expect(
      await failureOf(
        mock->MockSource.interceptGetItemsCalls([{fromBlock: 1, toBlock: None, p: "0"}]),
      ),
    ).toEqual(
      Some(`interceptGetItemsCalls timed out. Specs:
  #0 {p: "0", fromBlock: 1, toBlock: None} (matches no pending call)
Pending calls:
  none`),
    )
    mock.resolveGetHeightOrThrow(300)
    await mock->MockSource.interceptGetItemsCalls([
      {resolve: {items: [], latestFetchedBlockNumber: 300}},
    ])
    await indexer.getBatchWritePromise()
  })
})
