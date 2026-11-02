open Vitest

// The mock stamps every block header it returns with `timestamp = blockNumber`,
// so the metric's value names the block the timestamp was taken from.
let scenario = Scenario.make(
  ~configYaml=`
name: progress-block-time
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address:
          - "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

let rollbackScenario = Scenario.make(
  ~configYaml=`
name: progress-block-time-rollback
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

// Two addresses so `maxAddrInPartition=1` splits the chain into two partitions.
let twoPartitionScenario = Scenario.make(
  ~configYaml=`
name: progress-block-time-partitions
rollback_on_reorg: true
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address:
          - "0x0000000000000000000000000000000000000001"
          - "0x0000000000000000000000000000000000000002"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

let chainLabel = Dict.fromArray([("chainId", "1")])

let metricValue = async (indexer: IndexerRunner.t, name) =>
  (await indexer.metric(name))->Array.map(m => m.value)->Array.join(",")

// Progress block and its timestamp, sampled while a reorg resolves and
// deduplicated. Taken through the rollback rather than after it: the re-fetch
// restores progress within a few ticks, and the rolled-back state in between is
// what has to stay consistent. `lookup` is answered as soon as the rollback asks
// for it, while sampling goes on.
//
// `answerRefetch` covers the re-fetch queries the rollback schedules. A test
// that needs the rolled-back state to stay put leaves them pending instead:
// answering them carries progress forward again within a tick.
let traceThroughRollback = async (
  ~indexer: IndexerRunner.t,
  ~mock: MockSource.t,
  ~lookup=?,
  ~answerRefetch=false,
) => {
  let lookupAnswered = switch lookup {
  | Some(lookup) => mock.expectBlockHashLookup(lookup)
  | None => Promise.resolve()
  }
  let trace = []
  for _ in 0 to 300 {
    if answerRefetch && mock.pendingItemsQueries->Array.length > 0 {
      mock.drainPendingItemsQueries(~latestFetchedBlockNumber=301)
    }
    let sample = `${await metricValue(indexer, "envio_progress_block")}|${await metricValue(
        indexer,
        "envio_progress_block_time_seconds",
      )}`
    if trace->Array.last != Some(sample) {
      trace->Array.push(sample)->ignore
    }
    await Utils.delay(0)
  }
  await lookupAnswered
  trace
}

describe("Progress block time", () => {
  scenario->Scenario.it(
    "reports the timestamp of exactly the progress block, not of the last event's block",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      await mock.expectItemsQueries([{fromBlock: 1, reply: Respond({items: []})}])
      await mock.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Respond({items: [{blockNumber: 250, logIndex: 0}], latestFetchedBlockNumber: 300}),
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.metric("envio_progress_block_time_seconds"),
        ~message="progress reached block 300, so the timestamp is 300's - not event block 250's",
      ).toEqual([{value: "300", labels: chainLabel}])
    },
  )

  // Every block's header only pays for itself where blocks can still be
  // reorged, at the head, where the range is a handful of blocks. Over a
  // backfill range it would be a header per block for no gain.
  scenario->Scenario.it(
    "marks a query reorgable only once the chain is at the head",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      // Replying to a query drops it from the pending list, so each one's flag is
      // read while it is still in flight.
      let pendingFlags = () =>
        mock.pendingItemsQueries->Array.map(query => query->MockSource.reorgableFrom->Option.isSome)

      mock.resolveGetHeightOrThrow(300)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      let backfill = pendingFlags()
      await mock.respondEmptyUpTo(300)
      await indexer.getBatchWritePromise()
      await indexer.waitUntilReady()

      mock.resolveGetHeightOrThrow(301)
      await mock.expectItemsQueries([{fromBlock: 301, reply: LeavePending}])
      let head = pendingFlags()

      t.expect(
        [backfill, head],
        ~message="the backfill query asks only for the blocks its logs came from",
      ).toEqual([[false], [true]])
    },
  )

  scenario->Scenario.it(
    "restores the timestamp on resume, since a block's time doesn't change",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      await mock.respondEmptyUpTo(300)
      await indexer.getBatchWritePromise()

      let restarted = await indexer.restart()

      t.expect(
        await metricValue(restarted, "envio_progress_block_time_seconds"),
        ~message="reported from the first scrape of the resumed run, before any batch commits",
      ).toBe("300")
    },
  )

  // One partition can fetch ahead while the other holds the progress frontier
  // back, so the reorg lands above the block progress is committed at.
  twoPartitionScenario->Scenario.it(
    "keeps the timestamp when a reorg above the progress block leaves it where it is",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)

      mock.resolveGetHeightOrThrow(300)
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          reply: Respond({items: [], latestFetchedBlockNumber: 100}),
        },
        {
          partitionId: "1",
          fromBlock: 1,
          reply: Respond({items: [], latestFetchedBlockNumber: 100}),
        },
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        await metricValue(indexer, "envio_progress_block_time_seconds"),
        ~message="both partitions reached block 100, so progress is at 100",
      ).toBe("100")

      // Only partition 0 reaches the head, so the store learns block 300 while
      // the progress frontier - the minimum across partitions - stays at 100.
      // Partition 1 reports a different hash for block 300, so the reorg is
      // above the progress block and the rollback leaves progress at 100.
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 101,
          reply: Respond({items: [], latestFetchedBlockNumber: 300}),
        },
        {
          partitionId: "1",
          fromBlock: 101,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 300,
            latestFetchedBlockHash: "0x300a",
          }),
        },
      ])

      // Block 100 is the only stored block below the reorged 300, and the
      // source still agrees with it.
      let trace = await traceThroughRollback(
        ~indexer,
        ~mock,
        ~lookup={
          blockNumbers: [100],
          reply: [{blockNumber: 100, blockHash: "0x100", blockTimestamp: 100}],
        },
      )

      t.expect(
        trace,
        ~message="block 100 was never orphaned, so its timestamp is still its own",
      ).toEqual(["100|100"])
    },
  )

  rollbackScenario->Scenario.it(
    "drops the timestamp a rollback invalidates rather than keeping the orphaned block's",
    ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)

      // Head 300 with maxReorgDepth 200: the pre-threshold query stops at block
      // 100, the next one reaches the head.
      mock.resolveGetHeightOrThrow(300)
      await mock.expectItemsQueries([
        {fromBlock: 1, toBlock: Bounded(100), reply: Respond({items: []})},
      ])
      await indexer.getBatchWritePromise()
      await mock.expectItemsQueries([
        {fromBlock: 101, reply: Respond({items: [], latestFetchedBlockNumber: 300})},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        await metricValue(indexer, "envio_progress_block_time_seconds"),
        ~message="caught up to the head, so the head block's timestamp",
      ).toBe("300")

      // Block 300 comes back with a different hash, so it and everything above
      // the last valid block are orphaned.
      mock.resolveGetHeightOrThrow(301)
      await mock.expectItemsQueries([
        {
          fromBlock: 301,
          reply: Respond({items: [], prevRangeLastBlock: {blockNumber: 300, blockHash: "0x300a"}}),
        },
      ])

      let trace = await traceThroughRollback(~indexer, ~mock, ~answerRefetch=true)

      t.expect(
        mock.getBlockHashesCalls,
        ~message="no stored block in the reorg threshold lies below block 300, so there's nothing to look up",
      ).toEqual([])
      t.expect(
        trace,
        ~message="block 300 is orphaned, so its timestamp can't stand for the block progress lands on",
      ).toEqual(["300|300", "101|", "301|301"])
    },
  )
})
