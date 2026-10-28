open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: polling-stall
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
  ~virtualTime=true,
)

describe("Polling-stall loophole", () => {
  scenario->Scenario.it(
    "Stalls polling when chain buffer is at the head but events not yet processed",
    ~sources=[
      {
        chain: 1337,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        pollingInterval: 1,
      },
    ],
    ~sourceTiming={reducedPollingInterval: 10},
    async (~t as _, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(300)

      // Handler that never resolves keeps the batch in-progress,
      // so isReady stays false while the buffer sits at the head.
      let blockingHandler = async _ => {
        let _ = await Promise.make((_, _) => ())
      }
      await source.expectItemsQueries([
        {
          fromBlock: 1,
          toBlock: Unbounded,
          reply: Respond({
            items: [{blockNumber: 150, logIndex: 0, handler: blockingHandler}],
            latestFetchedBlockNumber: 300,
          }),
        },
      ])

      // Whatever the stuck wait asked before the window opens.
      await source.expectNewHeightCallsAtLeast(1)

      // The bug this pins is polling stopping altogether. Busy-polling would ask
      // on every tick; throttled polling asks once at the wait's start and then
      // once per 10ms reduced interval. Every poll is answered the moment it
      // arrives, so the count is how often the loop asks.
      source.setAutoHeight(300)
      await indexer.advanceTime(50)
      await source.expectNewHeightCalls(6)
    },
  )
})
