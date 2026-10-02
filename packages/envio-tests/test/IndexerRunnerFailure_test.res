open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: indexer-runner-failure
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
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

describe("An indexer failing under a test that passes no onError", () => {
  // The default used to exit the process, which killed the vitest worker
  // without naming the test or the error.
  Async.it("Fails the test with the indexer's error", async t => {
    let failure = switch await scenario->Scenario.run(
      ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
      async (~indexer as _, ~source) => {
        let source = source(1337)
        source.resolveGetHeightOrThrow(100)
        source.resolveGetItemsOrThrow(
          [
            {
              blockNumber: 50,
              logIndex: 0,
              handler: async _ => JsError.throwWithMessage("handler blew up"),
            },
          ],
          ~latestFetchedBlockNumber=100,
          ~knownHeight=100,
        )
        await Promise.make((_, _) => ())
      },
    ) {
    | () => None
    | exception JsExn(e) => e->JsExn.message
    }

    t.expect(failure).toEqual(Some("handler blew up"))
  })
})
