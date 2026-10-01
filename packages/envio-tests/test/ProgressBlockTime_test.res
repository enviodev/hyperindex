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
// what has to stay consistent. `validUpTo` is the last block the source still
// agrees with, which the depth search asks about one range at a time.
//
// `answerRefetch` covers the re-fetch queries the rollback schedules. A test
// that needs the rolled-back state to stay put leaves them pending instead:
// answering them carries progress forward again within a tick.
let traceThroughRollback = async (
  ~indexer: IndexerRunner.t,
  ~mock: MockSource.t,
  ~validUpTo,
  ~answerRefetch=false,
) => {
  let trace = []
  for _ in 0 to 300 {
    if mock.getBlockHashesCalls->Array.length > 0 {
      let requested = mock.getBlockHashesCalls->Array.copy
      mock.resolveGetBlockHashes(
        requested
        ->Array.flat
        ->Array.map((blockNumber): BlockStore.inputBlock => {
          blockNumber,
          blockHash: blockNumber <= validUpTo
            ? `0x${blockNumber->Int.toString}`
            : `0x${blockNumber->Int.toString}a`,
          blockTimestamp: blockNumber,
        }),
      )
      mock.getBlockHashesCalls->Utils.Array.clearInPlace
    }
    if answerRefetch && mock.getItemsOrThrowCalls->Array.length > 0 {
      mock.drainItemsQueries(~latestFetchedBlockNumber=301)
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
  trace
}

describe("Progress block time", () => {
  scenario->Scenario.it(
    "reports the timestamp of exactly the progress block, not of the last event's block",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetItemsOrThrow([{blockNumber: 250, logIndex: 0}], ~latestFetchedBlockNumber=300)
      mock.resolveGetHeightOrThrow(300)
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.metric("envio_progress_block_time_seconds"),
        ~message="progress reached block 300, so the timestamp is 300's - not event block 250's",
      ).toEqual([{value: "300", labels: chainLabel}])
    },
  )

  // The flag only pays for itself at the head, where the range is a handful of
  // blocks. Over a backfill range it would be a header per block for no gain.
  scenario->Scenario.it(
    "asks for every block in the range only once the chain is at the head",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      // Resolving a query drops it from the pending list, so each one's flag is
      // read while it is still in flight.
      let asked = []
      let recordPending = () =>
        mock.getItemsOrThrowCalls->Array.forEach(call =>
          asked->Array.push(call.includeAllBlocks)->ignore
        )

      mock.resolveGetHeightOrThrow(300)
      await MockSource.waitItemsQuery(mock)
      recordPending()
      mock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()
      await indexer.waitUntilReady()

      mock.resolveGetHeightOrThrow(301)
      await MockSource.waitItemsQuery(mock)
      recordPending()

      t.expect(
        asked,
        ~message="the backfill query asks only for the blocks its logs came from",
      ).toEqual([false, true])
    },
  )

  scenario->Scenario.it(
    "restores the timestamp on resume, since a block's time doesn't change",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      mock.resolveGetHeightOrThrow(300)
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
      let partition = p => (query: MockSource.itemsQuery) => query["p"] === p

      mock.resolveGetHeightOrThrow(300)
      await Scenario.waitUntil(
        () => mock.getItemsOrThrowCalls->Array.length === 2,
        ~message="both partitions query",
      )
      mock.resolveGetItemsOrThrow([], ~filter=partition("0"), ~latestFetchedBlockNumber=100)
      mock.resolveGetItemsOrThrow([], ~filter=partition("1"), ~latestFetchedBlockNumber=100)
      await indexer.getBatchWritePromise()

      t.expect(
        await metricValue(indexer, "envio_progress_block_time_seconds"),
        ~message="both partitions reached block 100, so progress is at 100",
      ).toBe("100")

      // Only partition 0 reaches the head, so the store learns block 300 while
      // the progress frontier - the minimum across partitions - stays at 100.
      mock.resolveGetItemsOrThrow([], ~filter=partition("0"), ~latestFetchedBlockNumber=300)

      // Partition 1 reports a different hash for block 300, so the reorg is
      // above the progress block and the rollback leaves progress at 100.
      mock.resolveGetItemsOrThrow(
        [],
        ~filter=partition("1"),
        ~latestFetchedBlockNumber=300,
        ~latestFetchedBlockHash="0x300a",
      )

      let trace = await traceThroughRollback(~indexer, ~mock, ~validUpTo=300)

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
      await MockSource.waitItemsQuery(mock)
      mock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
      await indexer.getBatchWritePromise()
      await MockSource.waitItemsQuery(mock)
      mock.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.getBatchWritePromise()

      t.expect(
        await metricValue(indexer, "envio_progress_block_time_seconds"),
        ~message="caught up to the head, so the head block's timestamp",
      ).toBe("300")

      // Block 300 comes back with a different hash, so it and everything above
      // the last valid block are orphaned.
      mock.resolveGetHeightOrThrow(301)
      await MockSource.waitItemsQuery(mock)
      mock.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=301,
        ~prevRangeLastBlock={blockNumber: 300, blockHash: "0x300a"},
      )

      let trace = await traceThroughRollback(~indexer, ~mock, ~validUpTo=299, ~answerRefetch=true)

      t.expect(
        trace,
        ~message="block 300 is orphaned, so its timestamp can't stand for the block progress lands on",
      ).toEqual(["300|300", "101|", "301|301"])
    },
  )
})
