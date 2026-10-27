open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: block-lag
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    block_lag: 1
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

describe("E2E blockLag tests", () => {
  scenario->Scenario.it(
    "Chain with blockLag=1 should be marked as synced to head when at knownHeight - blockLag",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    // The processing loop reaches the post-catch-up height poll on its own
    // cadence, so the test answers polls as they come rather than at a fixed
    // tick. Keep the re-poll fast.
    ~sourceTiming={reducedPollingInterval: 1},
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      // Enter reorg threshold the standard way:
      // knownHeight=300, maxReorgDepth=200, so initial fetch is blocks 1-100
      await Scenario.enterReorgThreshold(~indexer, ~source=sourceMock)

      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="Should be in reorg threshold",
      ).toEqual([{value: "1", labels: Dict.make()}])

      // Wait for the next query dispatch after entering reorg threshold

      // After entering reorg threshold, a new height poll fires.
      // Resolve it so the indexer can proceed.
      sourceMock.resolveGetHeightOrThrow(300)

      // After entering reorg threshold, blockLag is updated to chainConfig.blockLag=1.
      // The indexer fetches from block 101 up to knownHeight - blockLag = 299,
      // and gets items up to there.
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 101,
          toBlock: Bounded(299),
          retryCount: 0,
          reply: Respond({items: [{blockNumber: 101, logIndex: 0}]}),
        },
      ])
      await indexer.getBatchWritePromise()

      // With blockLag=1, progressBlockNumber=299 >= knownHeight(300) - blockLag(1) = 299,
      // so isProgressAtHead is true and chain IS synced to head.
      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="Chain with blockLag=1 should be synced to head because progress (299) >= knownHeight (300) - blockLag (1)",
      ).toEqual([{value: "1", labels: Dict.make()}])

      // The chain advanced to 301. Every height poll answers 301 from here on:
      // eager processing reaches the poll on its own cadence, so it can't be
      // answered at a fixed tick. The next fetch is from block 300 up to
      // knownHeight - blockLag = 300.
      sourceMock.setAutoHeight(301)
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 300,
          toBlock: Bounded(300),
          retryCount: 0,
          reply: Respond({items: [], knownHeight: 301}),
        },
      ])
      await indexer.getBatchWritePromise()

      // Still synced: progressBlockNumber=300 >= knownHeight(301) - blockLag(1) = 300
      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="Chain with blockLag=1 should still be synced after height advances",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )
})
