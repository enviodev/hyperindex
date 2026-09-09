open Vitest

// A DateTime64 column represents 1900-01-01 through 2299-12-31. RowBinary
// carries the raw tick, so a date past that lands without complaint and reads
// back as a different date — Postgres, which holds the same entity, keeps the
// one the handler wrote.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-date-range
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
  ~schema=`
type Plain {
  id: ID!
  value: String!
}

type Expiry @storage(clickhouse: {}) {
  id: ID!
  at: Timestamp!
}
`,
  ~unsupported=[
    {backend: #postgres, reason: "the ClickHouse-only entity needs a ClickHouse database"},
  ],
)

type expiry = {id: string, at: Date.t}
type expiryOps = {set: expiry => unit}
type handlerContext = {@as("Expiry") expiry: expiryOps}

let storedExpiries = async () => {
  let database = TestClickHouse.currentDatabase()
  let stored = await TestClickHouse.query(
    `SELECT count() FROM \`${database}\`.\`Expiry\` FORMAT TabSeparated`,
  )
  stored->String.trim
}

describe("ClickHouse refuses a date DateTime64 cannot represent", () => {
  let refusal = Scenario.captureRefusal()
  scenario->Scenario.it(
    "names the date and the range instead of storing a different date",
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
              context.expiry.set({id: "never", at: Date.fromString("9999-12-31T00:00:00.000Z")})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )

      let failure = await refusal.awaitStorageError()

      t.expect((
        failure->Option.map(((message, _)) => message),
        failure->Option.map(((_, reason)) => reason),
        await storedExpiries(),
      )).toEqual((
        Some("Failed to write a batch to ClickHouse"),
        Some(
          "Failed encoding rows for ClickHouse table `envio_history_Expiry`: encoding column `at` row 0: 9999-12-31T00:00:00.000Z is outside the range a DateTime64 column can hold, 1900-01-01 through 2299-12-31",
        ),
        "0",
      ))
    },
  )
})
