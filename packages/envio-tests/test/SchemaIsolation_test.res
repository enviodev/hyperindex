open Vitest

// The batch-set query has the schema baked into its text and used to be cached
// per table alone, so a second indexer in the same process sent its rows to the
// first one's schema. Two indexers back to back is what surfaces it: the second
// one writes into a schema that is no longer there.
let scenario = Scenario.make(
  ~configYaml=`
name: schema-isolation
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
type SimpleEntity {
  id: ID!
  value: String!
}
`,
)

type simpleEntity = {id: string, value: string}
type simpleEntityOps = {set: simpleEntity => unit}
type handlerContext = {@as("SimpleEntity") simpleEntity: simpleEntityOps}

describe("Schema isolation between indexers in one process", () => {
  let writeEntity = async (~value, ~onError) => {
    let rows = ref([])
    await scenario->Scenario.run(~sources=[{chain: 1337}], ~onError, async (~indexer, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(300)

      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 1,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              context.simpleEntity.set({id: "1", value})
            },
          },
        ],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      rows := (await (indexer.query("SimpleEntity"): promise<array<simpleEntity>>))
    })
    rows.contents
  }

  Async.it("writes land in the schema of the indexer that made them", async t => {
    // Recorded rather than fatal: a write against the first indexer's dropped
    // schema would otherwise take the whole worker down with it.
    let errors = []
    let onError = (errHandler: ErrorHandling.t) => {
      errors
      ->Array.push(
        errHandler.exn
        ->Utils.prettifyExn
        ->(Utils.magic: exn => JsExn.t)
        ->JsExn.message
        ->Option.getOr("unknown"),
      )
      ->ignore
    }

    let first = await writeEntity(~value="first", ~onError)
    let second = await writeEntity(~value="second", ~onError)

    t.expect(
      (first, second, errors),
      ~message="each indexer reads back its own write from its own storage",
    ).toEqual(([{id: "1", value: "first"}], [{id: "1", value: "second"}], []))
  })
})
