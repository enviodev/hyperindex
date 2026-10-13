open Vitest

// Sizes far past what a handler usually stores. A megabyte of text has to
// cross to the server and back in one piece, and a batch of an entity wide
// enough to bind more parameters than a statement can count (65535: 132
// columns at 500 rows) still has to land whole.

let columnCount = 140

let wideFields =
  Array.fromInitializer(~length=columnCount - 1, index =>
    `  f${index->Int.toString}: String!`
  )->Array.join("\n")

let scenario = Scenario.make(
  ~configYaml=`
name: storage-large-values
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
type Large {
  id: ID!
  text: String!
  blob: Bytes!
  tags: [String!]!
}

type Wide {
  id: ID!
${wideFields}
}
`,
)

type large = {id: string, text: string, blob: string, tags: array<string>}
type largeOps = {set: large => unit}
type wideOps = {set: dict<string> => unit}
type handlerContext = {@as("Large") large: largeOps, @as("Wide") wide: wideOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

let bigText = "a1b2c3d4"->String.repeat(140_000)

// 700KB, written as the hex string a Bytes field holds.
let bigBlob =
  "0x" ++
  Array.fromInitializer(~length=700_000, index =>
    mod(index * 7 + 11, 256)->Int.toString(~radix=16)->String.padStart(2, "0")
  )->Array.join("")

let wideRows = 501

let wide = row => {
  let entity = Dict.make()
  entity->Dict.set("id", row->Int.toString)
  for index in 0 to columnCount - 2 {
    entity->Dict.set(`f${index->Int.toString}`, `f${index->Int.toString}-${row->Int.toString}`)
  }
  entity
}

describe("A value of a size handlers rarely store", () => {
  scenario->Scenario.it(
    "is stored whole, and so is every row of a batch wider than a statement can bind",
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
              context.large.set({id: "large", text: bigText, blob: bigBlob, tags: [bigText, ""]})
              for row in 0 to wideRows - 1 {
                context.wide.set(wide(row))
              }
            },
          },
        ],
        ~latestFetchedBlockNumber=1,
      )
      await indexer.getBatchWritePromise()

      let large: array<large> = await indexer.query("Large")
      let wides: array<dict<string>> = await indexer.query("Wide")

      t.expect((
        large->Array.map(
          row => (row.text === bigText, row.blob === bigBlob, row.tags == [bigText, ""]),
        ),
        wides->Array.length,
        wides->Array.find(row => row->Dict.get("id") === Some("500")),
      )).toEqual(([(true, true, true)], wideRows, Some(wide(500))))
    },
  )
})
