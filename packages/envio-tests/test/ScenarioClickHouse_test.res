open Vitest

// Readers outside the indexer query the current-state view, which the indexer's
// own reads, `indexer.query` included, don't go through.

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

describe("Scenario ClickHouse", () => {
  scenario->Scenario.it(
    "serves an indexed entity through the current-state view",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
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

      let database = TestClickHouse.currentDatabase()
      let rows = await TestClickHouse.query(
        `SELECT id, count FROM \`${database}\`.\`Counter\` FORMAT JSONEachRow`,
      )
      t.expect(rows->String.trim).toEqual(`{"id":"total","count":"42"}`)
    },
  )
})
