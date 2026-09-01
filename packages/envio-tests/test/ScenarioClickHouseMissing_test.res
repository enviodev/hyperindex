open Vitest

// RowBinary carries no "absent", so a column the handler set nothing for has
// nowhere to go but the type's zero — a number the handler never chose, and one
// nothing downstream can tell from a number it did. The write refuses it.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-missing
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
  // ClickHouse-only, so Postgres — which would reject the missing column with
  // its own NOT NULL error — never sees the row and the refusal is the sink's.
  ~schema=`
type Plain {
  id: ID!
  value: String!
}

type Counted @storage(clickhouse: {}) {
  id: ID!
  amount: Int!
  label: String
}
`,
  ~unsupported=[
    {backend: #postgres, reason: "the ClickHouse-only entity needs a ClickHouse database"},
  ],
)

// `amount` is optional here and required in the schema: leaving it out is what a
// handler that forgot to set it produces.
type counted = {id: string, amount?: int, label?: string}
type countedOps = {set: counted => unit}
type handlerContext = {@as("Counted") counted: countedOps}

describe("ClickHouse refuses a required column the handler left unset", () => {
  let refusal = Scenario.captureRefusal()
  scenario->Scenario.it(
    "fails the write instead of storing the type's zero",
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
              // `label` is nullable, so leaving it out is legitimate; `amount`
              // is not, and is what the write has to catch.
              context.counted.set({id: "unset"})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )

      let failure = await refusal.awaitStorageError()

      let database = TestClickHouse.currentDatabase()
      let stored = await TestClickHouse.query(
        `SELECT count() FROM \`${database}\`.\`Counted\` FORMAT TabSeparated`,
      )

      t.expect((
        failure->Option.map(((message, _)) => message),
        failure->Option.mapOr(false, ((_, reason)) => reason->String.includes("amount")),
        stored->String.trim,
      )).toEqual((
        Some("Failed to convert items for ClickHouse table \"envio_history_Counted\""),
        true,
        "0",
      ))
    },
  )
})
