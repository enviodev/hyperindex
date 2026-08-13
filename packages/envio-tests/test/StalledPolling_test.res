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
      await Utils.delay(0)

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

      let deadline = Date.now() +. 50.
      while Date.now() < deadline {
        source.resolveGetHeightOrThrow(300)
        await Utils.delay(2)
      }

      let newCalls = source.getHeightOrThrowCalls->Array.length - baseline

      // A 50ms window at the 10ms reduced interval: polling has to continue,
      // but must not fire on every tick. The upper bound is loose because timer
      // coalescing under load changes the count without a regression.
      t.expect(
        newCalls > 1 && newCalls <= 15,
        ~message=`polling should continue but stay throttled while the batch is stuck (got ${newCalls->Int.toString})`,
      ).toBe(true)
    },
  )
})
