open Vitest

// A BigInt filter compares the integers it names whatever their size — uint256's
// upper half included, where keccak-derived ids and unlimited approvals live —
// and a scaled BigDecimal filter compares the value it names, not that value cut
// to the column's scale. A restart before the filters leaves nothing in memory to
// answer them from, so storage does.

let scenario = Scenario.make(
  ~configYaml=`
name: get-where-large-numbers
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
type Amount {
  id: ID!
  value: BigInt!
}

type Price {
  id: ID!
  value: BigDecimal! @config(precision: 10, scale: 2)
}

type Ratio {
  id: ID!
  value: BigDecimal!
}
`,
)

type amount = {id: string, value: bigint}
type price = {id: string, value: BigDecimal.t}
type amountFilter = {value?: Envio.whereOperator<bigint>}
type priceFilter = {value?: Envio.whereOperator<BigDecimal.t>}
type amountOps = {set: amount => unit, getWhere: amountFilter => promise<array<amount>>}
type priceOps = {set: price => unit, getWhere: priceFilter => promise<array<price>>}
type handlerContext = {
  @as("Amount") amount: amountOps,
  @as("Price") price: priceOps,
  @as("Ratio") ratio: priceOps,
}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => handlerContext)

let maxUint256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935n
let twoTo255 = 57896044618658097711785492504343953926634992332820282019728792003956564819968n

describe("getWhere on a large or scaled number", () => {
  scenario->Scenario.it(
    "compares the numbers a filter names, read off storage",
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
                  let context = args.context->asContext
                  [
                    ("max", maxUint256),
                    ("half", twoTo255),
                    ("minus", -1n),
                    ("zero", 0n),
                    ("hundred", 100n),
                  ]->Array.forEach(((id, value)) => context.amount.set({id, value}))
                  context.price.set({id: "price", value: BigDecimal.fromStringUnsafe("1.55")})
                },
              },
            ],
            latestFetchedBlockNumber: 5,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      let restarted = await indexer.restart()
      let found = ref(None)
      source.resolveGetHeightOrThrow(10)
      let readFilters: MockSource.itemMock = {
        blockNumber: 6,
        logIndex: 0,
        handler: async args => {
          let context = args.context->asContext
          let amounts = async filter =>
            (await context.amount.getWhere({value: filter}))
            ->Array.map(row => row.id)
            ->Array.toSorted(String.compare)
          let prices = async filter =>
            (await context.price.getWhere({value: filter}))->Array.map(row => row.id)
          found :=
            Some((
              await amounts({_gt: 0n}),
              await amounts({_lt: 100n}),
              await amounts({_eq: maxUint256}),
              await amounts({_gte: twoTo255}),
              await amounts({_in: [maxUint256, -1n]}),
              await prices({_eq: BigDecimal.fromStringUnsafe("1.555")}),
              await prices({_lt: BigDecimal.fromStringUnsafe("1.551")}),
              await prices({_gte: BigDecimal.fromStringUnsafe("1.551")}),
            ))
        },
      }
      await source.expectItemsQueries([
        {
          fromBlock: 6,
          toBlock: Unbounded,
          reply: Respond({items: [readFilters], latestFetchedBlockNumber: 10}),
        },
      ])
      await restarted.getBatchWritePromise()

      t.expect(found.contents).toEqual(
        Some((
          ["half", "hundred", "max"],
          ["minus", "zero"],
          ["max"],
          ["half", "max"],
          ["max", "minus"],
          [],
          ["price"],
          [],
        )),
      )
    },
  )
})

describe("getWhere on a scaled BigDecimal", () => {
  scenario->Scenario.it(
    "compares the digits a filter has past the column's scale",
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
                handler: async args =>
                  (args.context->asContext).price.set({
                    id: "price",
                    value: BigDecimal.fromStringUnsafe("1.55"),
                  }),
              },
            ],
            latestFetchedBlockNumber: 5,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      let restarted = await indexer.restart()
      let found = ref(None)
      source.resolveGetHeightOrThrow(10)
      let readFilters: MockSource.itemMock = {
        blockNumber: 6,
        logIndex: 0,
        handler: async args => {
          let context = args.context->asContext
          let prices = async filter =>
            (await context.price.getWhere({value: filter}))->Array.map(row => row.id)
          // A row one read loads answers every later read from memory, which
          // would cover a later read whose own query missed it. `_lt` is the
          // read a filter cut to the column's scale misses, so it goes first.
          let lt = await prices({_lt: BigDecimal.fromStringUnsafe("1.559")})
          let gt = await prices({_gt: BigDecimal.fromStringUnsafe("1.549")})
          let eq = await prices({_eq: BigDecimal.fromStringUnsafe("1.555")})
          found := Some((eq, lt, gt))
        },
      }
      await source.expectItemsQueries([
        {
          fromBlock: 6,
          toBlock: Unbounded,
          reply: Respond({items: [readFilters], latestFetchedBlockNumber: 10}),
        },
      ])
      await restarted.getBatchWritePromise()

      t.expect(found.contents).toEqual(Some(([], ["price"], ["price"])))
    },
  )
})

describe("getWhere on an unbounded BigDecimal", () => {
  scenario->Scenario.it(
    "compares values past any Decimal's digits, whole and fractional",
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
                  let context = args.context->asContext
                  [
                    ("max", maxUint256->BigInt.toString),
                    ("minus", "-" ++ maxUint256->BigInt.toString),
                    ("five", "5"),
                    ("tiny", "0.0000000000000000000000000000001"),
                  ]->Array.forEach(
                    ((id, value)) =>
                      context.ratio.set({id, value: BigDecimal.fromStringUnsafe(value)}),
                  )
                },
              },
            ],
            latestFetchedBlockNumber: 5,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      let restarted = await indexer.restart()
      let found = ref(None)
      source.resolveGetHeightOrThrow(10)
      let readFilters: MockSource.itemMock = {
        blockNumber: 6,
        logIndex: 0,
        handler: async args => {
          let context = args.context->asContext
          let ratios = async filter =>
            (await context.ratio.getWhere({value: filter}))
            ->Array.map(row => row.id)
            ->Array.toSorted(String.compare)
          let decimal = BigDecimal.fromStringUnsafe
          // A row one read loads answers every later read from memory, so each
          // read goes before any read that would load what it should find.
          let gt = await ratios({_gt: decimal("0")})
          let lt = await ratios({_lt: decimal("0")})
          let eq = await ratios({_eq: decimal("0")})
          let in_ = await ratios({_in: [maxUint256->BigInt.toString->decimal, decimal("5.0")]})
          let huge = await ratios({
            _gt: decimal("100000000000000000000000000000000000000000000000000"),
          })
          found := Some((gt, lt, eq, in_, huge))
        },
      }
      await source.expectItemsQueries([
        {
          fromBlock: 6,
          toBlock: Unbounded,
          reply: Respond({items: [readFilters], latestFetchedBlockNumber: 10}),
        },
      ])
      await restarted.getBatchWritePromise()

      t.expect(found.contents).toEqual(
        Some((["five", "max", "tiny"], ["minus"], [], ["five", "max"], ["max"])),
      )
    },
  )
})
