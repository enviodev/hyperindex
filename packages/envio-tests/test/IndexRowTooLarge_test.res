open Vitest

// PostgreSQL refuses a value too large for an index on its column, and says so
// without naming the column, the entity or what to change. ENS names are one
// such value: nothing bounds a label's length, and a spam registration carrying
// a long one stopped an indexer at the head.

let scenario = Scenario.make(
  ~configYaml=`
name: index-row-too-large
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
type Domain {
  id: ID!
  name: String @index
}
`,
  ~unsupported=Scenario.assertsPostgresIndexes,
)

type domain = {id: string, name: string}
type domainOps = {set: domain => unit}
type handlerContext = {@as("Domain") domain: domainOps}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

@scope("Math") @val external imul: (int, int) => int = "imul"

// Hex digits from a linear congruential generator. A repeated character would
// compress below the limit and be indexed after all.
let incompressible = length => {
  let state = ref(1)
  let digits = []
  for _ in 1 to length {
    state := imul(state.contents, 1103515245) + 12345
    digits
    ->Array.push(
      state.contents->Int.shiftRightUnsigned(16)->Int.bitwiseAnd(15)->Int.toString(~radix=16),
    )
    ->ignore
  }
  digits->Array.join("")
}

let longName = incompressible(24000)

let setLongName = async args => (args->contextOf).domain.set({id: "spam", name: longName})

describe("An indexed String field given a value too large to index", () => {
  let refusal = Scenario.captureRefusal()

  scenario->Scenario.it(
    "Names the field, the entity and what to change when the write is refused",
    ~sources=[{chain: 1337, autoHeight: 100}],
    ~onError=refusal.onError,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      await source.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 100})},
      ])
      await indexer.waitUntilReady()

      source.setAutoHeight(110)
      await source.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Respond({
            items: [{blockNumber: 105, logIndex: 0, handler: setLongName}],
            latestFetchedBlockNumber: 110,
          }),
        },
      ])

      t.expect(await refusal.awaitStorageError()).toEqual(
        Some((
          `Failed to write Domain with id "spam": field "name" is 24000 bytes, over the 2704 bytes a PostgreSQL index can hold. The field is indexed by @index in schema.graphql or by a getWhere filter on it. Truncate the value in the handler, e.g. \`value.slice(0, 512)\`, or remove that index. Value: "${longName->String.slice(
              ~start=0,
              ~end=32,
            )}…"`,
          "index row requires 24016 bytes, maximum size is 8191",
        )),
      )
    },
  )

  let failure = ref(None)

  scenario->Scenario.it(
    "Names the index and what to change when the index can't be built over it",
    ~sources=[{chain: 1337, autoHeight: 100}],
    ~onError=errHandler => failure := Some(errHandler),
    async (~t, ~indexer as _, ~source) => {
      await source(1337).expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [{blockNumber: 50, logIndex: 0, handler: setLongName}],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await Scenario.waitUntil(
        () => failure.contents->Option.isSome,
        ~message="the index build to fail",
        ~timeoutMs=15000.,
      )

      t.expect(
        failure.contents->Option.map(({exn}) =>
          (exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"]
        ),
      ).toEqual(
        Some(
          "Failed to build an index on \"Domain\"(\"name\"): a stored value is over the 2704 bytes a PostgreSQL index can hold. The field is indexed by @index in schema.graphql or by a getWhere filter on it. Truncate the value in the handler, e.g. `value.slice(0, 512)`, or remove that index.\nindex row requires 24016 bytes, maximum size is 8191",
        ),
      )
    },
  )
})
