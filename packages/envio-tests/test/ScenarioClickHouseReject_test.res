open Vitest

// RowBinary carries the raw integer, so a value the column cannot hold is not
// rejected anywhere downstream — the server takes whatever bytes it is handed
// and stores a different number. The sink has to refuse it instead, and the
// refusal has to reach the indexer as a storage error naming the table rather
// than being written and forgotten.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-reject
storage:
  postgres:
    default: true
  clickhouse: true
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
  // ClickHouse-only, so Postgres — whose NUMERIC(20, 0) has the same bound —
  // never sees the row and the refusal under test is the sink's alone.
  // Decimal(20, 0) holds 20 digits; the handler writes 21.
  ~schema=`
type Plain {
  id: ID!
  value: String!
}

type Bounded @storage(clickhouse: {}) {
  id: ID!
  amount: BigInt! @config(precision: 20)
}
`,
  ~unsupported=[
    {backend: #postgres, reason: "the ClickHouse-only entity needs a ClickHouse database"},
  ],
)

type bounded = {id: string, amount: bigint}
type boundedOps = {set: bounded => unit}
type handlerContext = {@as("Bounded") bounded: boundedOps}

describe("ClickHouse refuses a value its column cannot hold", () => {
  // Swallowed so it doesn't take the test worker down, and kept so the test can
  // assert on what an operator would have been shown.
  let refusal = Scenario.captureRefusal()
  scenario->Scenario.it(
    "fails the write instead of storing a different number",
    ~sources=[{chain: 1}],
    ~onError=refusal.onError,
    async (~t, ~indexer as _, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)

      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 5,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              context.bounded.set({id: "over", amount: 100000000000000000000n})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      let failure = await refusal.awaitStorageError()

      let database = TestClickHouse.currentDatabase()
      let stored = await TestClickHouse.query(
        `SELECT count() FROM \`${database}\`.\`Bounded\` FORMAT TabSeparated`,
      )

      t.expect((
        failure->Option.map(((message, _)) => message),
        failure->Option.mapOr(false, ((_, reason)) => reason->String.includes("Bounded")),
        failure->Option.mapOr(false, ((_, reason)) => reason->String.includes("out of range")),
        stored->String.trim,
      )).toEqual((Some("Failed to write a batch to ClickHouse"), true, true, "0"))
    },
  )
})
