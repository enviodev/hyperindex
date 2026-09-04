open Vitest

// An indexer that finds an existing storage never runs `initialize` — it takes
// the `resumeInitialState` path instead. The ClickHouse sink learns its table
// shapes at registration, so anything that only registers during initialize
// leaves a resumed indexer unable to write a single row.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-resume
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
  ~unsupported=[{backend: #postgres, reason: "asserts against a ClickHouse server"}],
)

type counter = {id: string, count: bigint}
type counterOps = {set: counter => unit}
type counterContext = {@as("Counter") counter: counterOps}

let setCounter = (~id, ~count) =>
  async (args: Internal.handlerArgs) => {
    let context = args.context->(Utils.magic: Internal.handlerContext => counterContext)
    context.counter.set({id, count})
  }

let feed = async (
  indexer: IndexerRunner.t,
  ~source: MockSource.t,
  ~blockNumber,
  // Answered once per indexer, and only while it is still asking: a chain far
  // from its head stays in backfill and fetches on without polling again.
  ~height=?,
  ~id="total",
  ~count,
) => {
  switch height {
  | Some(height) => source.resolveGetHeightOrThrow(height)
  | None => ()
  }
  source.resolveGetItemsOrThrow(
    [{blockNumber, logIndex: 0, handler: setCounter(~id, ~count)}],
    ~latestFetchedBlockNumber=blockNumber + 5,
  )
  await indexer.getBatchWritePromise()
}

describe("ClickHouse sink after a resume", () => {
  scenario->Scenario.it(
    "writes through a restart that resumes the existing storage",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await feed(indexer, ~source=source(1), ~blockNumber=5, ~height=10, ~count=42n)

      // The second indexer finds the storage the first one built, so it resumes
      // rather than initializing.
      let resumed = await indexer.restart()
      await feed(resumed, ~source=source(1), ~blockNumber=20, ~height=25, ~count=43n)

      let database = TestClickHouse.currentDatabase()
      let rows = await TestClickHouse.query(
        `SELECT id, count FROM \`${database}\`.\`Counter\` FORMAT JSONEachRow`,
      )
      t.expect(rows->String.trim).toEqual(`{"id":"total","count":"43"}`)
    },
  )

  scenario->Scenario.it(
    "keeps the rows it wrote before a restart during backfill",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      await feed(indexer, ~source=source(1), ~blockNumber=5, ~height=100000, ~id="first", ~count=1n)

      // Outside the reorg threshold Postgres saves no checkpoint at all, so the
      // committed checkpoint a resume trims back to is the one that means
      // "nothing committed" — while ClickHouse holds every row written so far.
      let checkpoints = await indexer.queryCheckpoints()

      let resumed = await indexer.restart()
      await feed(resumed, ~source=source(1), ~blockNumber=20, ~id="second", ~count=2n)

      let database = TestClickHouse.currentDatabase()
      let rows = await TestClickHouse.query(
        `SELECT id, count FROM \`${database}\`.\`Counter\` ORDER BY id FORMAT JSONEachRow`,
      )
      t.expect((checkpoints->Array.length, rows->String.trim->String.split("\n"))).toEqual((
        0,
        [`{"id":"first","count":"1"}`, `{"id":"second","count":"2"}`],
      ))
    },
  )
})
