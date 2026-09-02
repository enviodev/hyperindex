open Vitest

// A table option's expression may name schema fields, which the DDL resolves to
// their columns. A bare word in the expression can also be something else —
// the unit of `INTERVAL 30 day` — and a field named `day` must not claim it.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-expression-field
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
type Visit @storage(clickhouse: {ttl: "createdAt + INTERVAL 30 day"}) {
  id: ID!
  day: Int!
  createdAt: Timestamp!
}
`,
  ~unsupported=[{backend: #postgres, reason: "the table option is ClickHouse DDL"}],
)

type visit = {id: string, day: int, createdAt: Date.t}
type visitOps = {set: visit => unit}
type handlerContext = {@as("Visit") visit: visitOps}

describe("ClickHouse table options with a field named like a keyword", () => {
  scenario->Scenario.it(
    "creates the table with the field left as the interval unit it also is",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)

      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 5,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              context.visit.set({id: "v1", day: 3, createdAt: Date.fromTime(Date.now())})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()

      let database = TestClickHouse.currentDatabase()
      let ttl = await TestClickHouse.query(
        `SELECT engine_full FROM system.tables WHERE database = '${database}' AND name = 'envio_history_Visit' FORMAT TabSeparated`,
      )
      let rows = await TestClickHouse.query(
        `SELECT id, day FROM \`${database}\`.\`Visit\` FORMAT JSONEachRow`,
      )
      t.expect((
        ttl->String.includes("TTL createdAt + toIntervalDay(30)"),
        rows->String.trim,
      )).toEqual((true, `{"id":"v1","day":3}`))
    },
  )
})
