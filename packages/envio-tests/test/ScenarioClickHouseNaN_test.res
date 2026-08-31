open Vitest

// NaN and Infinity have no JSON form: `JSON.stringify` renders both as `null`,
// so a float array carrying one reaches the encoder as a null element the column
// cannot hold. What an operator reads has to name the value the handler actually
// wrote, not the null it turned into on the way.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-nan
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

type Readings @storage(clickhouse: {}) {
  id: ID!
  samples: [Float!]!
  latest: Float!
}
`,
  ~unsupported=[
    {backend: #postgres, reason: "the ClickHouse-only entity needs a ClickHouse database"},
  ],
)

type readings = {id: string, samples: array<float>, latest: float}
type readingsOps = {set: readings => unit}
type handlerContext = {@as("Readings") readings: readingsOps}

let storedReadings = async () => {
  let database = TestClickHouse.currentDatabase()
  let stored = await TestClickHouse.query(
    `SELECT count() FROM \`${database}\`.\`Readings\` FORMAT TabSeparated`,
  )
  stored->String.trim
}

describe("ClickHouse refuses a float that has no JSON form", () => {
  let refusal = Scenario.captureRefusal()
  scenario->Scenario.it(
    "names NaN rather than the null it serializes to",
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
              context.readings.set({id: "nan", samples: [1.5, %raw(`NaN`)], latest: 2.0})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )

      let failure = await refusal.awaitStorageError()

      t.expect((
        failure->Option.map(((message, _)) => message),
        failure->Option.map(((_, reason)) => reason),
        await storedReadings(),
      )).toEqual((
        Some("Failed to convert items for ClickHouse table \"envio_history_Readings\""),
        Some(
          "NaN has no JSON form, so it cannot be stored in the `samples` column. Store a finite number, or keep it out of the entity.",
        ),
        "0",
      ))
    },
  )
})

// A Float64 column takes the raw bytes, so nothing on the way rejects the two
// values the array path above refuses — ClickHouse stores them, and from then on
// an aggregate over the column is NaN and a JSON read has no form for it.
describe("ClickHouse refuses a non-finite float in a scalar column", () => {
  let refusal = Scenario.captureRefusal()
  scenario->Scenario.it(
    "fails the write instead of storing a value no reader can render",
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
              context.readings.set({id: "nan", samples: [1.5], latest: %raw(`Infinity`)})
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )

      let failure = await refusal.awaitStorageError()

      t.expect((
        failure->Option.map(((message, _)) => message),
        failure->Option.mapOr(false, ((_, reason)) => reason->String.includes("`latest`")),
        failure->Option.mapOr(
          false,
          ((_, reason)) => reason->String.includes("not a value a Float64 column can hold"),
        ),
        await storedReadings(),
      )).toEqual((Some("Failed to write a batch to ClickHouse"), true, true, "0"))
    },
  )
})
