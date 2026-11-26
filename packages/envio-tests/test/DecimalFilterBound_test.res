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
  amounts: [BigDecimal!]! @config(precision: 38, scale: 2)
}
`,
)

type wide = {
  id: string,
  amount: BigDecimal.t,
  narrow: BigDecimal.t,
  amounts: array<BigDecimal.t>,
}
type wideOps = {
  set: wide => unit,
  getWhere: dict<dict<unknown>> => promise<array<wide>>,
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

// A list compares element by element, so the first element off the column's
// grid decides the comparison, whatever follows it.
let listFilters = [
  ("_gte", ["0.011"]),
  ("_lt", ["0.015"]),
  ("_lte", ["0.01", "4.995"]),
  ("_gt", ["0.01", "4.995"]),
  ("_eq", ["0.01", "5"]),
]

let ids = (wides: array<wide>) => wides->Array.map(wide => wide.id)->Array.toSorted(String.compare)

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
                  amounts: [decimal(widestNarrow)],
                })
                context.wide.set({
                  id: "bottom",
                  amount: decimal(`-${widest}`),
                  narrow: decimal(`-${widestNarrow}`),
                  amounts: [decimal(`-${widestNarrow}`)],
                })
                context.wide.set({
                  id: "small",
                  amount: decimal("0.01"),
                  narrow: decimal("0.01"),
                  amounts: [decimal("0.01"), decimal("5")],
                })
              },
            ),
          ],
          latestFetchedBlockNumber: 1,
        }),
      },
    ])
    await indexer.getBatchWritePromise()

    let queries = Array.concat(
      ["amount", "narrow"]->Array.flatMap(
        field =>
          filters->Array.map(
            ((operator, bound)) => (
              field,
              operator,
              decimal(bound)->(Utils.magic: BigDecimal.t => unknown),
            ),
          ),
      ),
      listFilters->Array.map(
        ((operator, bound)) => (
          "amounts",
          operator,
          bound->Array.map(decimal)->(Utils.magic: array<BigDecimal.t> => unknown),
        ),
      ),
    )

    // Each filter runs in an indexer restarted for it: an entity a getWhere has
    // already loaded is matched in memory, so only the first one in a run is
    // answered by storage alone.
    let indexer = ref(indexer)
    let found = []
    for at in 0 to queries->Array.length - 1 {
      let (field, operator, bound) = queries->Array.getUnsafe(at)
      let block = at + 2
      source.setAutoHeight(100)
      indexer := (await indexer.contents.restart())
      await source.expectItemsQueries([
        {
          coversBlock: block,
          reply: Respond({
            items: [
              inHandler(
                ~block,
                async context => {
                  let wides = await context.wide.getWhere(
                    Dict.fromArray([(field, Dict.fromArray([(operator, bound)]))]),
                  )
                  found->Array.push((field, wides->ids))->ignore
                },
              ),
            ],
            latestFetchedBlockNumber: block,
          }),
        },
      ])
      await indexer.contents.getBatchWritePromise()
    }

    let expected = [["small", "top"], ["top"], ["bottom"], ["bottom"], [], ["small"]]
    t.expect(found).toEqual(
      Array.concat(
        ["amount", "narrow"]->Array.flatMap(field => expected->Array.map(ids => (field, ids))),
        [
          ("amounts", ["top"]),
          ("amounts", ["bottom", "small"]),
          ("amounts", ["bottom"]),
          ("amounts", ["small", "top"]),
          ("amounts", ["small"]),
        ],
      ),
    )
  })
})
