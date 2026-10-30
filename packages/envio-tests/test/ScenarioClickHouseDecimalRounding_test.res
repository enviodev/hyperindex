open Vitest

// A bounded BigDecimal is a numeric(P, S) in Postgres and a Decimal(P, S) in
// ClickHouse. An entity lands in both, so a value with more fractional digits
// than the scale has to settle the same way in each: Postgres rounds it half
// away from zero, and the encoder must not truncate it one ulp under that.

let scenario = Scenario.make(
  ~configYaml=`
name: clickhouse-decimal-rounding
storage:
  postgres:
    default: true
  clickhouse:
    default: true
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
type Price {
  id: ID!
  amount: BigDecimal! @config(precision: 10, scale: 2)
}
`,
  ~unsupported=Scenario.configuresOwnStorage,
)

type price = {id: string, amount: BigDecimal.t}
type priceOps = {set: price => unit}
type handlerContext = {@as("Price") price: priceOps}

describe("ClickHouse rounds a BigDecimal the way Postgres does", () => {
  scenario->Scenario.it("stores the same value in both stores", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
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
                let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
                context.price.set({id: "up", amount: BigDecimal.fromStringUnsafe("1.005")})
                context.price.set({id: "down", amount: BigDecimal.fromStringUnsafe("-1.005")})
                context.price.set({id: "under", amount: BigDecimal.fromStringUnsafe("1.00499")})
              },
            },
          ],
          latestFetchedBlockNumber: 10,
        }),
      },
    ])
    await indexer.getBatchWritePromise()

    let inPostgres: array<price> = await indexer.query("Price")
    let database = TestClickHouse.currentDatabase()
    let inClickHouse = await TestClickHouse.query(
      `SELECT id, toString(amount) AS amount FROM \`${database}\`.\`Price\` ORDER BY id FORMAT JSONEachRow`,
    )

    t.expect((
      inPostgres
      ->Array.map(({id, amount}) => (id, amount.toString()))
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b)),
      inClickHouse->String.trim,
    )).toEqual((
      [("down", "-1.01"), ("under", "1"), ("up", "1.01")],
      `{"id":"down","amount":"-1.01"}\n{"id":"under","amount":"1"}\n{"id":"up","amount":"1.01"}`,
    ))
  })
})

let unboundedScenario = Scenario.make(
  ~configYaml=`
name: clickhouse-decimal-notation
storage:
  postgres:
    default: true
  clickhouse:
    default: true
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
type Ratio {
  id: ID!
  value: BigDecimal!
}
`,
  ~unsupported=Scenario.configuresOwnStorage,
)

type ratio = {id: string, value: BigDecimal.t}
type ratioOps = {set: ratio => unit}
type ratioContext = {@as("Ratio") ratio: ratioOps}

// An unbounded BigDecimal is text in ClickHouse, kept as written, so it has to
// be written the way Postgres renders its numeric: never in exponent notation.
describe("ClickHouse keeps an unbounded BigDecimal as Postgres renders it", () => {
  unboundedScenario->Scenario.it(
    "writes a very small or very large value without an exponent",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
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
                  let context = args.context->(Utils.magic: Internal.handlerContext => ratioContext)
                  context.ratio.set({
                    id: "large",
                    value: BigDecimal.fromStringUnsafe("12500000000000000000000000"),
                  })
                  context.ratio.set({
                    id: "small",
                    value: BigDecimal.fromStringUnsafe("1000000").div(
                      BigDecimal.fromStringUnsafe("1000000000000000000"),
                    ),
                  })
                },
              },
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      let database = TestClickHouse.currentDatabase()
      let inClickHouse = await TestClickHouse.query(
        `SELECT id, value FROM \`${database}\`.\`Ratio\` ORDER BY id FORMAT JSONEachRow`,
      )
      await indexer.usePostgresSql(async sql => {
        let inPostgres: array<{"id": string, "value": string}> = await sql->Sql.queryForTests(
          `SELECT "id", "value"::text AS "value" FROM "${indexer.pgSchema}"."Ratio" ORDER BY "id";`,
        )
        t.expect((
          inPostgres->Array.map(row => `{"id":"${row["id"]}","value":"${row["value"]}"}`),
          inClickHouse->String.trim->String.split("\n"),
        )).toEqual((
          [
            `{"id":"large","value":"12500000000000000000000000"}`,
            `{"id":"small","value":"0.000000000001"}`,
          ],
          [
            `{"id":"large","value":"12500000000000000000000000"}`,
            `{"id":"small","value":"0.000000000001"}`,
          ],
        ))
      })
    },
  )
})
