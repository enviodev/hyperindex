open Vitest

// Every column type a schema can declare, written by a handler and read back
// two ways: straight from the table, and by a handler of a restarted indexer,
// whose `get` and `getWhere` have nothing in memory and must decode the rows.
// Each value sits at an edge its column has to keep: punctuation an array
// literal reads, digits a double would lose, an empty value beside a null.

let scenario = Scenario.make(
  ~configYaml=`
name: storage-column-round-trip
chains:
  - id: 1337
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
enum Kind {
  FIRST
  SECOND
}

type Owner {
  id: ID!
  items: [Item!]! @derivedFrom(field: "owner")
}

type Item {
  id: ID!
  text: String!
  maybeText: String
  int: Int!
  maybeInt: Int
  float: Float!
  flag: Boolean!
  big: BigInt!
  sizedBig: BigInt! @config(precision: 30)
  decimal: BigDecimal!
  scaledDecimal: BigDecimal! @config(precision: 12, scale: 4)
  at: Timestamp!
  maybeAt: Timestamp
  bytes: Bytes!
  doc: Json!
  kind: Kind!
  texts: [String!]!
  ints: [Int!]!
  bigs: [BigInt!]!
  decimals: [BigDecimal!]!
  kinds: [Kind!]!
  tag: String! @index
  owner: Owner!
}
`,
)

type owner = {id: string}
type item = {
  id: string,
  text: string,
  maybeText: option<string>,
  int: int,
  maybeInt: option<int>,
  float: float,
  flag: bool,
  big: bigint,
  sizedBig: bigint,
  decimal: BigDecimal.t,
  scaledDecimal: BigDecimal.t,
  at: Date.t,
  maybeAt: option<Date.t>,
  bytes: string,
  doc: JSON.t,
  kind: string,
  texts: array<string>,
  ints: array<int>,
  bigs: array<bigint>,
  decimals: array<BigDecimal.t>,
  kinds: array<string>,
  tag: string,
  owner_id: string,
}
type itemOps = {
  set: item => unit,
  get: string => promise<option<item>>,
  getWhere: {"tag": {"_eq": string}} => promise<array<item>>,
}
type ownerOps = {set: owner => unit}
type handlerContext = {@as("Item") item: itemOps, @as("Owner") owner: ownerOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

let decimal = BigDecimal.fromStringUnsafe

// Values at the edges of what each column keeps.
let full: item = {
  id: `a,b{"x"}\\`,
  text: `quote " backslash \\ brace { comma , NULL`,
  maybeText: Some("present"),
  int: -2147483648,
  maybeInt: Some(2147483647),
  float: 1.5e-300,
  flag: true,
  big: 123456789012345678901234567890n,
  sizedBig: -999999999999999999999999999999n,
  decimal: decimal("-0.000000000000000000001"),
  scaledDecimal: decimal("12345678.1235"),
  at: Date.fromTime(-86399999.),
  maybeAt: Some(Date.fromTime(1700000000123.)),
  bytes: "0x00ff0010",
  doc: JSON.parseOrThrow(`{"nested":[1,true,null,"s"],"unicode":"héllo 😀"}`),
  kind: "SECOND",
  texts: ["", "NULL", `a,b`, `"q"`, `{}`, "😀"],
  ints: [0, -1, 2147483647],
  bigs: [0n, -1n, 99999999999999999999999n],
  decimals: [decimal("1.5"), decimal("-0.25")],
  kinds: ["SECOND", "FIRST"],
  tag: "full",
  owner_id: "owner",
}

let empty: item = {
  id: "",
  text: "",
  maybeText: None,
  int: 0,
  maybeInt: None,
  float: 0.,
  flag: false,
  big: 0n,
  sizedBig: 0n,
  decimal: decimal("0"),
  scaledDecimal: decimal("0"),
  at: Date.fromTime(0.),
  maybeAt: None,
  bytes: "0x",
  doc: JSON.Encode.array([]),
  kind: "FIRST",
  texts: [],
  ints: [],
  bigs: [],
  decimals: [],
  kinds: [],
  tag: "empty",
  owner_id: "owner",
}

// BigDecimal compares by identity in `toEqual`, so assertions
// read every row through the same plain rendering.
let render = (item: item) => (
  item.id,
  item.text,
  item.maybeText,
  item.int,
  item.maybeInt,
  item.float,
  item.flag,
  item.big,
  item.sizedBig,
  item.decimal->BigDecimal.toString,
  item.scaledDecimal->BigDecimal.toString,
  item.at->Date.getTime,
  item.maybeAt->Option.map(Date.getTime),
  item.bytes,
  item.doc,
  item.kind,
  item.texts,
  item.ints,
  item.bigs,
  item.decimals->Array.map(BigDecimal.toString),
  item.kinds,
  item.tag,
  item.owner_id,
)

let byId = (items: array<item>) =>
  items->Array.toSorted((a, b) => String.compare(a.id, b.id))->Array.map(render)

describe("Every column type", () => {
  scenario->Scenario.it(
    "is stored as written and decoded the same by a restarted indexer's handlers",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=100)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 1,
            logIndex: 0,
            handler: async args => {
              let context = args->contextOf
              context.owner.set({id: "owner"})
              context.item.set(full)
              context.item.set(empty)
            },
          },
        ],
        ~latestFetchedBlockNumber=1,
      )
      await indexer.getBatchWritePromise()
      let stored: array<item> = await indexer.query("Item")

      sourceMock.setAutoHeight(100)
      let restarted = await indexer.restart()

      // Copies of what `get` and `getWhere` return: anything they decode
      // differently from how it was written comes back changed.
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 2,
            logIndex: 0,
            handler: async args => {
              let context = args->contextOf
              switch await context.item.get(full.id) {
              | Some(item) => context.item.set({...item, id: "got:full", tag: "copy"})
              | None => ()
              }
              switch await context.item.get(empty.id) {
              | Some(item) => context.item.set({...item, id: "got:empty", tag: "copy"})
              | None => ()
              }
              let found = await context.item.getWhere({"tag": {"_eq": "full"}})
              found->Array.forEach(
                item => context.item.set({...item, id: "where:full", tag: "copy"}),
              )
            },
          },
        ],
        ~filter=MockSource.coveringBlock(2),
        ~latestFetchedBlockNumber=2,
      )
      await restarted.getBatchWritePromise()
      let copies: array<item> = await restarted.query("Item")
      let copyOf = id =>
        copies
        ->Array.find(item => item.id === id)
        ->Option.map(item => render({...item, id: "", tag: ""}))
      let original = item => Some(render({...item, id: "", tag: ""}))

      t.expect((
        stored->byId,
        [copyOf("got:full"), copyOf("got:empty"), copyOf("where:full")],
      )).toEqual(([empty, full]->byId, [original(full), original(empty), original(full)]))
    },
  )
})
