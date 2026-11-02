open Vitest

// A query covering blocks that can still be reorged tells the source so, which
// is what makes every page link to the one before it for reorg detection. That
// starts when the chain enters the reorg threshold, not once the indexer is
// realtime: catching up the last max_reorg_depth blocks happens in between.
let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: reorgable-range
chains:
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
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
}
`,
)

describe("Reorgable range", () => {
  scenario->Scenario.it(
    "marks a query reorgable from the moment the chain enters the reorg threshold",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~reorgThresholdReadyTolerance=100,
    ~sourceTiming={reducedPollingInterval: 1},
    ~targetBufferSize=100,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)
      // Replying to a query drops it from the pending list, so each one's
      // marker is read while it is still in flight.
      let pendingReorgableFrom = () =>
        source.pendingItemsQueries->Array.map(MockSource.reorgableFrom)

      source.resolveGetHeightOrThrow(1000)
      await source.expectItemsQueries([{toBlock: Bounded(800), reply: LeavePending}])
      let backfill = pendingReorgableFrom()
      await source.respondEmptyUpTo(800)
      await indexer.getBatchWritePromise()

      // Inside the threshold, still catching up to the head at 1000, so the
      // indexer isn't realtime yet.
      await source.expectItemsQueries([{fromBlock: 801, reply: LeavePending}])
      let catchUp = pendingReorgableFrom()

      t.expect(
        [backfill, catchUp],
        ~message="below the threshold every block is final; inside it, blocks from head - max_reorg_depth can be reorged",
      ).toEqual([[None], [Some(800)]])
    },
  )
})
