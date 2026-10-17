open Vitest

// Guards the ClickHouse leg against being a silent no-op: the sink is attached
// by config, so a scenario can run green on it while writing nothing at all.
// Reading entity state back through ClickHouse is otherwise out of scope — the
// other scenarios assert through Postgres.

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
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ context }) => {
  context.Counter.set({ id: "total", count: 42n });
});
`,
  ~unsupported=[{backend: #postgres, reason: "asserts against a ClickHouse server"}],
)

describe("Scenario ClickHouse sink", () => {
  scenario->Scenario.it("mirrors an indexed entity into ClickHouse", ~sources=[{chain: 1}], async (
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
          items: [{event: "Token.Transfer", blockNumber: 5, logIndex: 0}],
          latestFetchedBlockNumber: 10,
        }),
      },
    ])
    await indexer.getBatchWritePromise()

    // The current-state view the sink builds over its history table, which is
    // what mirrors the Postgres row.
    let database = TestClickHouse.currentDatabase()
    let rows = await TestClickHouse.query(
      `SELECT id, count FROM \`${database}\`.\`Counter\` FORMAT JSONEachRow`,
    )
    t.expect(rows->String.trim).toEqual(`{"id":"total","count":"42"}`)
  })
})
