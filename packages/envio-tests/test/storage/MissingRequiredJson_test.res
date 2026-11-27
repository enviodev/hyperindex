open Vitest

// JSON `null` is a document of its own, which a required Json field stores.
// A field the handler left out is no document at all, and is refused like any
// other required field left out.

let scenario = Scenario.make(
  ~configYaml=`
name: missing-required-json
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
type Note {
  id: ID!
  payload: Json!
}
`,
)

type handlerContext = {@as("Note") note: {"set": unknown => unit}}

let contextOf = (args: Internal.handlerArgs) =>
  args.context->(Utils.magic: Internal.handlerContext => handlerContext)

let setNote = (sourceMock: MockSource.t, note) =>
  sourceMock.expectItemsQueries([
    {
      fromBlock: 1,
      toBlock: Unbounded,
      reply: Respond({
        items: [
          {
            blockNumber: 1,
            logIndex: 0,
            handler: async args => (args->contextOf).note["set"](note),
          },
        ],
      }),
    },
  ])

describe("A required Json field", () => {
  let refusal = Scenario.captureRefusal()

  scenario->Scenario.it(
    "left out is refused, naming the field",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    ~onError=refusal.onError,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~source=sourceMock, ~head=100)
      await sourceMock->setNote(%raw(`{id: "1"}`))
      let failure = await refusal.awaitRefusalReason()

      let stored: array<unknown> = await indexer.query("Note")

      t.expect((failure, stored)).toEqual((
        Some(
          "No value for the `payload` column, which is not nullable. Set the field before saving the entity, or make it optional in the schema.",
        ),
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "set to null stores the document null",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~source=sourceMock, ~head=100)
      await sourceMock->setNote(%raw(`{id: "1", payload: null}`))
      await indexer.getBatchWritePromise()

      let stored: array<unknown> = await indexer.query("Note")

      t.expect(stored).toEqual([%raw(`{id: "1", payload: null}`)])
    },
  )
})
