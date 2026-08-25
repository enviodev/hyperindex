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
    {backend: #memory, reason: "asserts against a ClickHouse server"},
    {backend: #postgres, reason: "the ClickHouse-only entity needs a ClickHouse database"},
  ],
)

type readings = {id: string, samples: array<float>, latest: float}
type readingsOps = {set: readings => unit}
type handlerContext = {@as("Readings") readings: readingsOps}

let refusal: ref<option<ErrorHandling.t>> = ref(None)

let rec awaitRefusal = async ticks =>
  switch refusal.contents {
  | Some(_) as seen => seen
  | None if ticks > 0 =>
    await Utils.delay(10)
    await awaitRefusal(ticks - 1)
  | None => None
  }

describe("ClickHouse refuses a float that has no JSON form", () => {
  scenario->Scenario.it(
    "names NaN rather than the null it serializes to",
    ~sources=[{chain: 1}],
    ~onError=errHandler => refusal := Some(errHandler),
    async (~t, ~indexer as _, ~source) => {
      let source = source(1)
      await Utils.delay(0)
      source.resolveGetHeightOrThrow(10)
      await Utils.delay(0)
      await Utils.delay(0)

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

      let failure = switch await awaitRefusal(1000) {
      | Some({exn: Persistence.StorageError({message, reason})}) =>
        Some((
          message,
          (reason->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"],
        ))
      | _ => None
      }

      let database = TestClickHouse.currentDatabase()
      let stored = await TestClickHouse.query(
        `SELECT count() FROM \`${database}\`.\`Readings\` FORMAT TabSeparated`,
      )

      t.expect((
        failure->Option.map(((message, _)) => message),
        failure->Option.map(((_, reason)) => reason),
        stored->String.trim,
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
