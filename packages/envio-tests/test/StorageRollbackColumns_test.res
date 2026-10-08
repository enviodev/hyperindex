open Vitest

// A reorg restores entities from their history rows, so every column type has
// to survive being written to history and copied back. Values are changed
// after the rollback target and must come back exactly as they were before it.

let scenario = Scenario.make(
  ~configYaml=`
name: storage-rollback-columns
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
enum Kind {
  FIRST
  SECOND
}

type Item {
  id: ID!
  text: String!
  maybeText: String
  big: BigInt!
  decimal: BigDecimal!
  at: Timestamp!
  bytes: Bytes!
  doc: Json!
  kind: Kind!
  texts: [String!]!
  bigs: [BigInt!]!
}

type Numbered {
  id: Int!
  value: String!
}
`,
)

type item = {
  id: string,
  text: string,
  maybeText: option<string>,
  big: bigint,
  decimal: BigDecimal.t,
  at: Date.t,
  bytes: string,
  doc: JSON.t,
  kind: string,
  texts: array<string>,
  bigs: array<bigint>,
}
type numbered = {id: int, value: string}
type itemOps = {set: item => unit, deleteUnsafe: string => unit}
type numberedOps = {set: numbered => unit}
type handlerContext = {@as("Item") item: itemOps, @as("Numbered") numbered: numberedOps}

let at = (~block, write: handlerContext => unit): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    args.context->(Utils.magic: Internal.handlerContext => handlerContext)->write,
}

let before: item = {
  id: "item",
  text: `a,b {"q"} \\`,
  maybeText: Some("kept"),
  big: 123456789012345678901234567890n,
  decimal: BigDecimal.fromStringUnsafe("-12.0005"),
  at: Date.fromTime(1700000000123.),
  bytes: "0x00ff",
  doc: JSON.parseOrThrow(`{"a":[1,null,"x"]}`),
  kind: "SECOND",
  texts: ["", "NULL", "x,y"],
  bigs: [-1n, 99999999999999999999n],
}

let after: item = {
  id: "item",
  text: "changed",
  maybeText: None,
  big: 0n,
  decimal: BigDecimal.fromStringUnsafe("0"),
  at: Date.fromTime(0.),
  bytes: "0x",
  doc: JSON.Encode.array([]),
  kind: "FIRST",
  texts: [],
  bigs: [],
}

let render = (item: item) => (
  item.id,
  item.text,
  item.maybeText,
  item.big,
  item.decimal->BigDecimal.toString,
  item.at->Date.getTime,
  item.bytes,
  item.doc,
  item.kind,
  item.texts,
  item.bigs,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

// Head 300 with a reorg depth of 200: block 50 lands below the threshold and
// is the state the rollback has to return to; block 200 lands inside it.
let indexBeforeAndAfter = async (
  ~indexer: IndexerRunner.t,
  ~source: MockSource.t,
  ~below: handlerContext => unit,
  ~inside: handlerContext => unit,
) => {
  source.resolveGetHeightOrThrow(300)
  await Utils.delay(0)
  await Utils.delay(0)
  await MockSource.waitItemsQuery(source)
  source.resolveGetItemsOrThrow([at(~block=50, below)], ~latestFetchedBlockNumber=100)
  await indexer.getBatchWritePromise()
  await MockSource.waitItemsQuery(source)
  source.resolveGetItemsOrThrow([at(~block=200, inside)], ~latestFetchedBlockNumber=300)
  await indexer.getBatchWritePromise()
}

describe("A rollback", () => {
  scenario->Scenario.it(
    "restores every column of an entity changed after the target",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      await indexBeforeAndAfter(
        ~indexer,
        ~source,
        ~below=context => {
          context.item.set(before)
          context.numbered.set({id: 7, value: "before"})
        },
        ~inside=context => {
          context.item.set(after)
          context.numbered.set({id: 7, value: "after"})
        },
      )
      let changed: array<item> = await indexer.query("Item")

      await Scenario.reorgAbove(~indexer, ~source, ~head=300, ~validUpTo=100)
      let items: array<item> = await indexer.query("Item")
      let numbered: array<numbered> = await indexer.query("Numbered")

      t.expect((changed->Array.map(render), items->Array.map(render), numbered)).toEqual((
        [after->render],
        [before->render],
        [{id: 7, value: "before"}],
      ))
    },
  )

  scenario->Scenario.it(
    "brings back an entity deleted after the target",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      await indexBeforeAndAfter(
        ~indexer,
        ~source,
        ~below=context => context.item.set(before),
        ~inside=context => context.item.deleteUnsafe(before.id),
      )
      let deleted: array<item> = await indexer.query("Item")

      await Scenario.reorgAbove(~indexer, ~source, ~head=300, ~validUpTo=100)
      let items: array<item> = await indexer.query("Item")

      t.expect((deleted->Array.map(render), items->Array.map(render))).toEqual((
        [],
        [before->render],
      ))
    },
  )
})
