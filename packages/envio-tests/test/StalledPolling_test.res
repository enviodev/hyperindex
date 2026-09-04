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
    ~reducedPollingInterval=10,
    async (~t, ~indexer as _, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Handler that never resolves keeps the batch in-progress,
      // so isReady stays false while the buffer sits at the head.
      let blockingHandler = async _ => {
        let _ = await Promise.make((_, _) => ())
      }
      source.resolveGetItemsOrThrow(
        [{blockNumber: 150, logIndex: 0, handler: blockingHandler}],
        ~latestFetchedBlockNumber=300,
      )

      await Utils.delay(5)

      let baseline = source.getHeightOrThrowCalls->Array.length

      // Answer every poll the moment it arrives: the measurement is how often
      // the loop asks, not how promptly the test replies.
      source.setAutoHeight(300)
      let deadline = Date.now() +. 50.
      while Date.now() < deadline {
        await Utils.delay(2)
      }

      let newCalls = source.getHeightOrThrowCalls->Array.length - baseline

      // The bug this pins is polling stopping altogether (0-1 calls). The upper
      // bound separates throttled polling from busy-polling, which fires on
      // every tick and reaches the hundreds — it is not a rate measurement, so
      // it sits an order of magnitude above the ~5 a healthy 50ms window at the
      // 10ms interval produces. A tighter bound flakes on timer coalescing.
      t.expect(
        newCalls > 1 && newCalls <= 40,
        ~message=`polling should continue but stay throttled while the batch is stuck (got ${newCalls->Int.toString})`,
      ).toBe(true)
    },
  )
})
