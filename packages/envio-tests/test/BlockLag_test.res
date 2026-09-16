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
    ~reducedPollingInterval=1,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await Utils.delay(0)
      // Enter reorg threshold the standard way:
      // knownHeight=300, maxReorgDepth=200, so initial fetch is blocks 1-100
      await Scenario.enterReorgThreshold(~t, ~indexer, ~source=sourceMock)

      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="Should be in reorg threshold",
      ).toEqual([{value: "1", labels: Dict.make()}])

      // Wait for the next query dispatch after entering reorg threshold

      // After entering reorg threshold, a new height poll fires.
      // Resolve it so the indexer can proceed.
      sourceMock.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // After entering reorg threshold, blockLag is updated to chainConfig.blockLag=1.
      // The indexer fetches from block 101 up to knownHeight - blockLag = 299.
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
        ~message="Should request items from block 101 to 299 (knownHeight - blockLag)",
      ).toEqual(Some({"fromBlock": 101, "toBlock": Some(299), "retry": 0, "p": "0"}))

      // Resolve the pending fetch with items up to block 299 (knownHeight - blockLag).
      sourceMock.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 101,
            logIndex: 0,
          },
        ],
        ~latestFetchedBlockNumber=299,
      )
      await indexer.getBatchWritePromise()

      // With blockLag=1, progressBlockNumber=299 >= knownHeight(300) - blockLag(1) = 299,
      // so isProgressAtHead is true and chain IS synced to head.
      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="Chain with blockLag=1 should be synced to head because progress (299) >= knownHeight (300) - blockLag (1)",
      ).toEqual([{value: "1", labels: Dict.make()}])

      // The chain advanced to 301. Answer height polls with 301 until the
      // indexer issues its next fetch (eager processing reaches the poll on its
      // own cadence, so we can't resolve at a fixed tick).
      let attempt = ref(0)
      while sourceMock.getItemsOrThrowCalls->Utils.Array.isEmpty {
        if attempt.contents >= 200 {
          JsError.throwWithMessage("Timed out waiting for the next getItemsOrThrow call")
        }
        sourceMock.resolveGetHeightOrThrow(301)
        await Utils.delay(0)
        attempt := attempt.contents + 1
      }

      // Should request from block 300 up to knownHeight - blockLag = 300.
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload)->Utils.Array.last,
        ~message="Should request items from block 300 to 300 (knownHeight 301 - blockLag 1)",
      ).toEqual(Some({"fromBlock": 300, "toBlock": Some(300), "retry": 0, "p": "0"}))

      // Advance chain height to 301 and resolve fetch up to block 300.
      sourceMock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300, ~knownHeight=301)
      await indexer.getBatchWritePromise()

      // Still synced: progressBlockNumber=300 >= knownHeight(301) - blockLag(1) = 300
      t.expect(
        await indexer.metric("hyperindex_synced_to_head"),
        ~message="Chain with blockLag=1 should still be synced after height advances",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )
})
