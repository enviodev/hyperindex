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

describe("Polling while the chain waits for new blocks", () => {
  makeScenario(
    ~name="unknown-height",
    ~rollbackOnReorg=false,
  )->Scenario.it(
    "Polls at the source interval while the chain has no known height",
    ~sources=sources(~height=0),
    ~sourceTiming={reducedPollingInterval: reducedPollingInterval},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await mock.expectNewHeightCalls(1)
      // Reduced polling is for a chain that knows where the head is. Before the
      // first height lands there is nothing to be idle about, so it polls every
      // 1ms of the source's interval rather than every reduced 1000ms.
      await indexer.advanceTime(10)
      await mock.expectNewHeightCalls(10)
    },
  )

  makeScenario(
    ~name="height-below-reorg-lag",
    ~rollbackOnReorg=true,
  )->Scenario.it(
    "Keeps reduced polling when the known height is below the lag holding the head back",
    ~sources=sources(~height=50),
    ~sourceTiming={reducedPollingInterval: reducedPollingInterval},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await mock.expectNewHeightCalls(1)
      // The cadence the first wait slept on, chosen before any height landed.
      await indexer.advanceTime(1)
      await mock.expectNewHeightCalls(1)
      // Pre-threshold the lag is the whole reorg depth, so a chain 50 blocks
      // long can't fetch anything - but it does know its head, and asking for it
      // faster would buy nothing.
      await indexer.advanceTime(reducedPollingInterval - 1)
      await mock.expectNewHeightCalls(0)
      await indexer.advanceTime(1)
      await mock.expectNewHeightCalls(1)
    },
  )
})
