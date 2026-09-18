open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: unknown-height-polling
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
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

describe("Polling before the head is known", () => {
  scenario->Scenario.it(
    "Polls at the source interval while the chain has no known height",
    ~sources=[
      {
        chain: 1337,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        pollingInterval: 1,
        // Every poll is answered with a height the waiter can't be satisfied by,
        // so the loop keeps asking and the gaps between calls are its cadence.
        autoHeight: 0,
      },
    ],
    ~reducedPollingInterval=1000,
    async (~t, ~indexer as _, ~source) => {
      let source = source(1337)

      let deadline = Date.now() +. 50.
      while Date.now() < deadline {
        await Utils.delay(2)
      }

      let calls = source.getHeightOrThrowCalls->Array.length

      // Reduced polling belongs to a chain sitting at a head it knows. Before
      // the first height lands there is no head to sit at, so the window has to
      // hold many polls at the 1ms interval rather than the single one a 1000ms
      // reduced interval leaves room for. The bound is loose because the
      // measurement is which cadence is in force, not the rate itself.
      t.expect(
        calls > 5,
        ~message=`should poll at the source interval while the height is unknown (got ${calls->Int.toString})`,
      ).toBe(true)
    },
  )
})
