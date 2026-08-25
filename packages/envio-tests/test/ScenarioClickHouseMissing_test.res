open Vitest

// A column the handler set nothing for used to be stored as the type's zero:
// RowBinary carries no "absent", so the encoder wrote the default ClickHouse
// would have substituted. That is a number the handler never chose, and nothing
// downstream can tell it from one it did. The write has to refuse it instead.

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
    {backend: #memory, reason: "asserts against a ClickHouse server"},
    {backend: #postgres, reason: "the ClickHouse-only entity needs a ClickHouse database"},
  ],
)

// `amount` is optional here and required in the schema: leaving it out is what a
// handler that forgot to set it produces.
type counted = {id: string, amount?: int, label?: string}
type countedOps = {set: counted => unit}
type handlerContext = {@as("Counted") counted: countedOps}

let refusal: ref<option<ErrorHandling.t>> = ref(None)

let rec awaitRefusal = async ticks =>
  switch refusal.contents {
  | Some(_) as seen => seen
  | None if ticks > 0 =>
    await Utils.delay(10)
    await awaitRefusal(ticks - 1)
  | None => None
  }

describe("ClickHouse refuses a required column the handler left unset", () => {
  scenario->Scenario.it(
    "fails the write instead of storing the type's zero",
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
              // `label` is nullable, so leaving it out is legitimate; `amount`
              // is not, and is what the write has to catch.
              context.counted.set({id: "unset"})
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
        `SELECT count() FROM \`${database}\`.\`Counted\` FORMAT TabSeparated`,
      )

      t.expect((
        failure->Option.map(((message, _)) => message),
        failure->Option.mapOr(false, ((_, reason)) => reason->String.includes("amount")),
        stored->String.trim,
      )).toEqual((Some("Failed to convert items for ClickHouse table \"envio_history_Counted\""), true, "0"))
    },
  )
})
