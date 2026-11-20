open Vitest

// https://github.com/enviodev/hyperindex/issues/1816
// A getWhere bound can carry more fractional digits than the column's scale.
// ClickHouse compares a Decimal against one of a wider scale by scaling the
// column's value up, which wraps past 256 bits for a value near the top of a
// precision-76 column and answers the comparison wrong. The same filters have
// to find the same rows as they do in Postgres, which compares exactly, on a
// precision-38 column too, whose values ClickHouse compares as 256-bit ones.

let scenario = Scenario.make(
  ~configYaml=`
name: decimal-filter-bound
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Wide {
  id: ID!
  amount: BigDecimal! @config(precision: 76, scale: 2)
  narrow: BigDecimal! @config(precision: 38, scale: 2)
}
`,
)

type wide = {id: string, amount: BigDecimal.t, narrow: BigDecimal.t}
type wideOps = {
  set: wide => unit,
  getWhere: dict<dict<BigDecimal.t>> => promise<array<wide>>,
}
type handlerContext = {@as("Wide") wide: wideOps}

let inHandler = (~block, run: handlerContext => promise<unit>): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    await args.context->(Utils.magic: Internal.handlerContext => handlerContext)->run,
}

let decimal = BigDecimal.fromStringUnsafe
let widest = `${"9"->String.repeat(74)}.99`
let widestNarrow = `${"9"->String.repeat(36)}.99`

let filters = [
  ("_gt", "0.001"),
  ("_gte", "0.011"),
  ("_lt", "0.001"),
  ("_lte", "-0.001"),
  ("_eq", "0.011"),
  ("_eq", "0.010"),
]

describe("A getWhere bound finer than a Decimal column's scale", () => {
  scenario->Scenario.it("finds the rows it would in Postgres", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1)
    await Scenario.resolveInitialHeight(~source, ~head=100)

    await source.expectItemsQueries([
      {
        coversBlock: 1,
        reply: Respond({
          items: [
            inHandler(
              ~block=1,
              async context => {
                context.wide.set({
                  id: "top",
                  amount: decimal(widest),
                  narrow: decimal(widestNarrow),
                })
                context.wide.set({
                  id: "bottom",
                  amount: decimal(`-${widest}`),
                  narrow: decimal(`-${widestNarrow}`),
                })
                context.wide.set({id: "small", amount: decimal("0.01"), narrow: decimal("0.01")})
              },
            ),
          ],
          latestFetchedBlockNumber: 1,
        }),
      },
    ])
    await indexer.getBatchWritePromise()

    // Restarted, so the getWhere is answered by storage rather than memory.
    source.setAutoHeight(100)
    let indexer = await indexer.restart()
    let found = []
    await source.expectItemsQueries([
      {
        coversBlock: 2,
        reply: Respond({
          items: [
            inHandler(
              ~block=2,
              async context =>
                for field in 0 to 1 {
                  let field = ["amount", "narrow"]->Array.getUnsafe(field)
                  for at in 0 to filters->Array.length - 1 {
                    let (operator, bound) = filters->Array.getUnsafe(at)
                    let ids =
                      (
                        await context.wide.getWhere(
                          Dict.fromArray([(field, Dict.fromArray([(operator, decimal(bound))]))]),
                        )
                      )
                      ->Array.map(wide => wide.id)
                      ->Array.toSorted(String.compare)
                    found->Array.push((field, ids))->ignore
                  }
                },
            ),
          ],
          latestFetchedBlockNumber: 2,
        }),
      },
    ])
    await indexer.getBatchWritePromise()

    let expected = [["small", "top"], ["top"], ["bottom"], ["bottom"], [], ["small"]]
    t.expect(found).toEqual(
      ["amount", "narrow"]->Array.flatMap(field => expected->Array.map(ids => (field, ids))),
    )
  })
})
