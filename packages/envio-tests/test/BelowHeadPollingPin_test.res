open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: below-head-polling
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 100
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 700
    block_lag: 700
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    block_lag: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

describe("PIN: chains keep indexing after entering the reorg threshold", () => {
  scenario->Scenario.it(
    "a chain at its lagged head does not prevent another chain from reaching readiness",
    ~sources=[
      // This chain's configured lag is the same as its pre-threshold reorg
      // depth. Once it reaches block 300 it has no newly exposed work when the
      // indexer enters the threshold, so it parks in WaitingForNewBlock.
      {chain: 100, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
      // This chain initially stops at 1000 - 200 = 800. Entering the threshold
      // removes its lag, exposing blocks 801..1000 that must still be queried
      // before the multichain indexer can become ready.
      {chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
    ],
    ~reducedPollingInterval=1,
    ~targetBufferSize=100,
    async (~t, ~indexer, ~source) => {
      let chainAtLaggedHead = source(100)
      let chainWithThresholdWork = source(1337)
      chainAtLaggedHead.resolveGetHeightOrThrow(1000)
      chainWithThresholdWork.resolveGetHeightOrThrow(1000)
      await Utils.delay(0)
      await Utils.delay(0)

      // Chain 100 wins the initial priority tie. Its events seed a density
      // signal, which is required for it to establish the bad alignment line
      // after the threshold despite having no query of its own to run.
      await MockSource.waitItemsQuery(chainAtLaggedHead)
      t.expect(
        chainAtLaggedHead.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="the high-lag chain first fetches to its pre-threshold head",
      ).toEqual([1])
      let densitySeed: array<MockSource.itemMock> = Array.fromInitializer(
        ~length=100,
        i => {
          MockSource.blockNumber: 1 + i * 3,
          logIndex: 0,
        },
      )
      chainAtLaggedHead.resolveGetItemsOrThrow(
        densitySeed,
        ~latestFetchedBlockNumber=300,
        ~knownHeight=1000,
      )
      await indexer.getBatchWritePromise()

      await MockSource.waitItemsQuery(chainWithThresholdWork)
      t.expect(
        chainWithThresholdWork.getItemsOrThrowCalls->Array.map(
          call => call.payload["fromBlock"],
        ),
        ~message="the zero-lag chain first fetches to its pre-threshold head",
      ).toEqual([1])
      chainWithThresholdWork.resolveGetItemsOrThrow(
        [{MockSource.blockNumber: 100, logIndex: 0}],
        ~latestFetchedBlockNumber=400,
        ~knownHeight=1000,
      )
      await indexer.getBatchWritePromise()

      // Commit firstEventBlock before the response that reaches the lagged
      // head. Otherwise the threshold tick sees this chain at synthetic 0%
      // progress and lets it lead, which sidesteps the production ordering.
      await MockSource.waitItemsQuery(chainWithThresholdWork)
      t.expect(
        chainWithThresholdWork.getItemsOrThrowCalls->Array.map(
          call => call.payload["fromBlock"],
        ),
        ~message="the second response reaches the zero-lag chain's pre-threshold head",
      ).toEqual([401])
      chainWithThresholdWork.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=800,
        ~knownHeight=1000,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="both chains reached their pre-threshold lagged heads",
      ).toEqual([{value: "1", labels: Dict.make()}])

      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="the indexer must not be ready before chain 1337 fetches 801..1000",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Prove that ordinary polling does not heal the stall. Same-height
      // responses keep waitForNewBlock's internal polling loop alive, but do
      // not re-enter the cross-chain scheduler. Skip this loop once the bug is
      // fixed and chain 1337 already has its expected query.
      for _ in 1 to 3 {
        if chainWithThresholdWork.getItemsOrThrowCalls->Utils.Array.isEmpty {
          let heightCallCount = chainAtLaggedHead.getHeightOrThrowCalls->Array.length
          chainAtLaggedHead.resolveGetHeightOrThrow(1000)

          let attempts = ref(0)
          while (
            chainAtLaggedHead.getHeightOrThrowCalls->Array.length <= heightCallCount &&
              attempts.contents < 1000
          ) {
            attempts := attempts.contents + 1
            await Utils.delay(0)
          }
          t.expect(
            chainAtLaggedHead.getHeightOrThrowCalls->Array.length > heightCallCount,
            ~message="the stuck source continues polling at the unchanged height",
          ).toBe(true)
        }
      }

      // The shared buffer is empty here: no buffered items and no in-flight
      // queries. Chain 100 consumes none of the available 100-item budget because it
      // is already at knownHeight - blockLag. Chain 1337 must therefore receive
      // that pool and query its newly exposed range. The buggy scheduler instead
      // lets chain 100 claim the progress-alignment line before discovering that
      // it is WaitingForNewBlock, which clamps chain 1337 behind block 800.
      t.expect(
        chainWithThresholdWork.getItemsOrThrowCalls->Array.map(
          call => call.payload["fromBlock"],
        ),
        ~message="the below-head chain is not blocked by an unchanged source",
      ).toEqual([801])

      chainWithThresholdWork.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=1000,
        ~knownHeight=1000,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="all chains become ready after the threshold catch-up finishes",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )
})
