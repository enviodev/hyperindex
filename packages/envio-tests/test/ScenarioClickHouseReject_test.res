open Vitest

// RowBinary carries the raw integer, so a value the column cannot hold is not
// rejected anywhere downstream — the server takes whatever bytes it is handed
// and stores a different number. The store has to refuse it instead, and the
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
  // `Bounded` is ClickHouse-only, so Postgres — whose NUMERIC(20, 0) has the
  // same bound — never sees the row and the refusal under test is
  // ClickHouse's alone. `PgBounded` is the same bound in Postgres alone.
  // Decimal(20, 0) holds 20 digits; the handler writes 21.
  ~schema=`
type PgBounded {
  id: ID!
  amount: BigInt! @config(precision: 20)
}

type Bounded @storage(clickhouse: {}) {
  id: ID!
  amount: BigInt! @config(precision: 20)
}

type Note @storage(clickhouse: {}) {
  id: ID!
  text: String!
}
`,
  ~unsupported=Scenario.configuresOwnStorage,
)

type bounded = {id: string, amount: bigint}
type boundedOps = {set: bounded => unit}
type note = {id: string, text: string}
type noteOps = {set: note => unit}
type handlerContext = {
  @as("Bounded") bounded: boundedOps,
  @as("PgBounded") pgBounded: boundedOps,
  @as("Note") note: noteOps,
}

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

      await source.expectItemsQueries([
        {
          fromBlock: 0,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              {
                blockNumber: 5,
                logIndex: 0,
                handler: async args => {
                  let context =
                    args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                  context.bounded.set({id: "over", amount: 100000000000000000000n})
                },
              },
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
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

describe("Both stores refuse their halves of one batch", () => {
  let refusal = Scenario.captureRefusal()
  scenario->Scenario.it(
    "reports each store's refusal",
    ~sources=[{chain: 1}],
    ~onError=refusal.onError,
    async (~t, ~indexer as _, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)

      await source.expectItemsQueries([
        {
          fromBlock: 0,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              {
                blockNumber: 5,
                logIndex: 0,
                handler: async args => {
                  let context =
                    args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                  context.pgBounded.set({id: "over", amount: 100000000000000000000n})
                  context.bounded.set({id: "over", amount: 100000000000000000000n})
                },
              },
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      let reason = await refusal.awaitRefusalReason()

      t.expect((
        reason->Option.mapOr(false, reason => reason->String.includes("out of range")),
        reason->Option.mapOr(false, reason => reason->String.includes("numeric field overflow")),
      )).toEqual((true, true))
    },
  )
})

describe("A batch Postgres refuses", () => {
  let refusal = Scenario.captureRefusal()
  scenario->Scenario.it(
    "is never readable in the ClickHouse following it",
    ~sources=[{chain: 1}],
    ~onError=refusal.onError,
    async (~t, ~indexer as _, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)

      await source.expectItemsQueries([
        {
          fromBlock: 0,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              {
                blockNumber: 5,
                logIndex: 0,
                handler: async args => {
                  let context =
                    args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                  context.note.set({id: "landed", text: "only ClickHouse takes it"})
                  context.pgBounded.set({id: "over", amount: 100000000000000000000n})
                },
              },
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      let reason = await refusal.awaitRefusalReason()

      let database = TestClickHouse.currentDatabase()
      let readable = await TestClickHouse.query(
        `SELECT count() FROM \`${database}\`.\`Note\` FORMAT TabSeparated`,
      )

      t.expect((
        reason->Option.mapOr(false, reason => reason->String.includes("numeric field overflow")),
        readable->String.trim,
      )).toEqual((true, "0"))
    },
  )
})
