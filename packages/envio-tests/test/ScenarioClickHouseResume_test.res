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
  ~unsupported=[
    {backend: #memory, reason: "asserts against a ClickHouse server"},
    {backend: #postgres, reason: "asserts against a ClickHouse server"},
  ],
)

type counter = {id: string, count: bigint}
type counterOps = {set: counter => unit}
type counterContext = {@as("Counter") counter: counterOps}

let setCounter = (~count) => async (args: Internal.handlerArgs) => {
  let context = args.context->(Utils.magic: Internal.handlerContext => counterContext)
  context.counter.set({id: "total", count})
}

describe("ClickHouse sink after a resume", () => {
  scenario->Scenario.it(
    "writes through a restart that resumes the existing storage",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let feed = async (indexer: IndexerRunner.t, ~source: MockSource.t, ~blockNumber, ~count) => {
        source.resolveGetHeightOrThrow(blockNumber + 5)
        source.resolveGetItemsOrThrow(
          [{blockNumber, logIndex: 0, handler: setCounter(~count)}],
          ~latestFetchedBlockNumber=blockNumber + 5,
        )
        await indexer.getBatchWritePromise()
      }

      await feed(indexer, ~source=source(1), ~blockNumber=5, ~count=42n)

      // The second indexer finds the storage the first one built, so it resumes
      // rather than initializing.
      let resumed = await indexer.restart()
      await feed(resumed, ~source=source(1), ~blockNumber=20, ~count=43n)

      let database = TestClickHouse.currentDatabase()
      let rows = await TestClickHouse.query(
        `SELECT id, count FROM \`${database}\`.\`Counter\` FORMAT JSONEachRow`,
      )
      t.expect(rows->String.trim).toEqual(`{"id":"total","count":"43"}`)
    },
  )
})
