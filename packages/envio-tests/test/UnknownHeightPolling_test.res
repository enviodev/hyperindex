open Vitest

let makeScenario = (~name, ~rollbackOnReorg) =>
  Scenario.make(
    ~configYaml=`
name: ${name}
rollback_on_reorg: ${rollbackOnReorg ? "true" : "false"}
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

// Answers every height call with a height that leaves the wait unsatisfied, so
// the loop keeps asking and the gaps between calls are the cadence under test.
let sources = (~height): array<Scenario.sourceMock> => [
  {
    chain: 1337,
    methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
    pollingInterval: 1,
    autoHeight: height,
  },
]

let reducedPollingInterval = 1000

let countPolls = async (~source: MockSource.t) => {
  let deadline = Date.now() +. 50.
  while Date.now() < deadline {
    await Utils.delay(2)
  }
  source.getHeightOrThrowCalls->Array.length
}

describe("Polling while the chain waits for new blocks", () => {
  makeScenario(~name="unknown-height", ~rollbackOnReorg=false)->Scenario.it(
    "Polls at the source interval while the chain has no known height",
    ~sources=sources(~height=0),
    ~reducedPollingInterval,
    async (~t, ~indexer as _, ~source) => {
      let calls = await countPolls(~source=source(1337))

      // Reduced polling is for a chain that knows where the head is. Before the
      // first height lands there is nothing to be idle about, so the window has
      // to hold many polls at the 1ms interval rather than the single one a
      // 1000ms reduced interval leaves room for. The bound is loose because the
      // measurement is which cadence is in force, not the rate itself.
      t.expect(
        calls > 5,
        ~message=`should poll at the source interval while the height is unknown (got ${calls->Int.toString})`,
      ).toBe(true)
    },
  )

  makeScenario(~name="height-below-reorg-lag", ~rollbackOnReorg=true)->Scenario.it(
    "Keeps reduced polling when the known height is below the lag holding the head back",
    ~sources=sources(~height=50),
    ~reducedPollingInterval,
    async (~t, ~indexer as _, ~source) => {
      let calls = await countPolls(~source=source(1337))

      // Pre-threshold the lag is the whole reorg depth, so a chain 50 blocks
      // long can't fetch anything - but it does know its head, and asking for it
      // faster would buy nothing. Only the first wait (at height 0) polls at the
      // source interval; once the height lands the cadence drops back.
      t.expect(
        calls <= 4,
        ~message=`should stay on reduced polling once a height is known (got ${calls->Int.toString})`,
      ).toBe(true)
    },
  )
})
