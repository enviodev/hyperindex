open Vitest

// The current-state view is what readers outside the indexer query; every other scenario reads ClickHouse through the indexer's own load path.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-scenario
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

describe("Scenario ClickHouse", () => {
  scenario->Scenario.it("keeps an indexed entity in ClickHouse", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1)
    source.resolveGetHeightOrThrow(10)

    await source.expectItemsQueries([
      {
        fromBlock: 0,
        toBlock: Unbounded,
        reply: Respond({
          items: [
            {
              blockNumber: 5,
              logIndex: 0,
              handler: async args => {
                let context = args.context->(Utils.magic: Internal.handlerContext => counterContext)
                context.counter.set({id: "total", count: 42n})
              },
            },
          ],
          latestFetchedBlockNumber: 10,
        }),
      },
    ])
    await indexer.getBatchWritePromise()

    // The current-state view ClickHouse builds over its history table.
    let database = TestClickHouse.currentDatabase()
    let rows = await TestClickHouse.query(
      `SELECT id, count FROM \`${database}\`.\`Counter\` FORMAT JSONEachRow`,
    )
    t.expect(rows->String.trim).toEqual(`{"id":"total","count":"42"}`)
  })
})
