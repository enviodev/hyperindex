open Vitest

// A per-chain entity's chain id is the scope's rather than the entity's: the
// handler never sets it, and two chains writing the same id are two rows that
// only the chain id tells apart. Nothing else asserts on the column, so a write
// path that dropped it or filled it from the wrong scope would land silently.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-per-chain
disable_default_cross_chain: true
# The chain id column is renamed by the format, so the constant has to reach
# the column the table actually declares rather than the field's own name.
storage:
  postgres:
    default: true
    column_name_format: original
  clickhouse:
    default: true
    column_name_format: snake_case
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 137
    rpc:
      url: https://rpc137.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000002"
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
  ~unsupported=[
    {backend: #postgres, reason: "asserts against a ClickHouse server"},
  ],
)

type counter = {id: string, count: bigint}
type counterOps = {set: counter => unit}
type counterContext = {@as("Counter") counter: counterOps}

let setCounter = (~count) => {
  MockSource.blockNumber: 5,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => counterContext)
    context.counter.set({id: "total", count})
  },
}

describe("Scenario ClickHouse per-chain entity", () => {
  scenario->Scenario.it(
    "stamps each row with the chain that wrote it",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      let chain1 = source(1)
      let chain137 = source(137)

      chain1.resolveGetHeightOrThrow(10)
      chain137.resolveGetHeightOrThrow(10)

      await MockSource.waitItemsQuery(chain1)
      chain1.resolveGetItemsOrThrow([setCounter(~count=42n)], ~latestFetchedBlockNumber=10)
      await MockSource.waitItemsQuery(chain137)
      chain137.resolveGetItemsOrThrow([setCounter(~count=7n)], ~latestFetchedBlockNumber=10)
      await indexer.waitUntilReady()

      let database = TestClickHouse.currentDatabase()
      // The history table rather than the view: the chain id is what the view
      // dedups on, not a column it selects.
      let rows = await TestClickHouse.query(
        `SELECT id, count, chain_id FROM \`${database}\`.\`envio_history_Counter\` ORDER BY chain_id FORMAT JSONEachRow`,
      )
      t.expect(
        rows->String.trim,
      ).toEqual(`{"id":"total","count":"42","chain_id":1}\n{"id":"total","count":"7","chain_id":137}`)
    },
  )
})
