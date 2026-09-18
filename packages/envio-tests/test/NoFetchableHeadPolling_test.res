open Vitest

// A chain can be waiting for new blocks without being anywhere near its head:
// until `knownHeight - blockLag` clears zero there is nothing it could fetch,
// whatever height it has observed. Each scenario below reaches that state by a
// different route, and all of them are a chain still looking for its head
// rather than one idling at it.
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

// Answers every height call with a height that leaves nothing fetchable, so the
// wait never settles and the gaps between calls are the cadence under test.
let sources = (~height): array<Scenario.sourceMock> => [
  {
    chain: 1337,
    methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
    pollingInterval: 1,
    autoHeight: height,
  },
]

let measurePolling = async (~t: Vitest.testContext, ~source: MockSource.t) => {
  let deadline = Date.now() +. 50.
  while Date.now() < deadline {
    await Utils.delay(2)
  }

  let calls = source.getHeightOrThrowCalls->Array.length

  // Reduced polling belongs to a chain idling at a head it can fetch. Without
  // one, the window has to hold many polls at the 1ms interval rather than the
  // single one a 1000ms reduced interval leaves room for. The bound is loose
  // because the measurement is which cadence is in force, not the rate itself.
  t.expect(
    calls > 5,
    ~message=`should poll at the source interval while no head is fetchable (got ${calls->Int.toString})`,
  ).toBe(true)
}

describe("Polling before a fetchable head is known", () => {
  makeScenario(~name="unknown-height", ~rollbackOnReorg=false)->Scenario.it(
    "Polls at the source interval while the chain has no known height",
    ~sources=sources(~height=0),
    ~reducedPollingInterval=1000,
    async (~t, ~indexer as _, ~source) => await measurePolling(~t, ~source=source(1337)),
  )

  makeScenario(~name="height-below-reorg-depth", ~rollbackOnReorg=true)->Scenario.it(
    "Polls at the source interval while the known height is below the pre-threshold reorg lag",
    ~sources=sources(~height=50),
    ~reducedPollingInterval=1000,
    async (~t, ~indexer as _, ~source) => await measurePolling(~t, ~source=source(1337)),
  )
})
