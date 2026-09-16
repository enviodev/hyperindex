open Vitest

// Rollback, entity history and resume, asserted the same way on every backend.
// The in-memory storage used to have none of the three — it threw on the
// rollback queries and kept no history — so these cases could only ever run
// against Postgres.

let scenario = Scenario.make(
  ~configYaml=`
name: rollback-scenario
rollback_on_reorg: true
save_full_history: true
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

type counter = {id: string, count: bigint}
type counterOps = {set: counter => unit}
type counterContext = {@as("Counter") counter: counterOps}

let setCounter = (~block, ~count): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => counterContext)
    context.counter.set({id: "total", count})
  },
}

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

// Head 300 with maxReorgDepth 200: the pre-threshold query stops at block 100,
// and the next one reaches the head.
let enterThresholdAndIndex = async (~indexer: IndexerRunner.t, ~source: MockSource.t) => {
  source.resolveGetHeightOrThrow(300)
  await Utils.delay(0)
  await Utils.delay(0)

  await MockSource.waitItemsQuery(source)
  source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=100)
  await indexer.getBatchWritePromise()

  await MockSource.waitItemsQuery(source)
  source.resolveGetItemsOrThrow([setCounter(~block=200, ~count=1n)], ~latestFetchedBlockNumber=300)
  await indexer.getBatchWritePromise()
}

// Answers whatever the reorg resolution asks for: block hashes for the depth
// search (blocks past `validUpTo` come back re-orged), and empty responses for
// the re-fetch queries the rollback schedules.
let driveRollback = async (~source: MockSource.t, ~validUpTo) => {
  for _ in 0 to 300 {
    if source.getBlockHashesCalls->Array.length > 0 {
      let requested = source.getBlockHashesCalls->Array.copy
      source.resolveGetBlockHashes(
        requested
        ->Array.flat
        ->Array.map((blockNumber): BlockStore.inputBlock => {
          blockNumber,
          // Past `validUpTo` the chain is orphaned, so the hash the source
          // reports differs from the one the store recorded.
          blockHash: blockNumber <= validUpTo
            ? `0x${blockNumber->Int.toString}`
            : `0x${blockNumber->Int.toString}a`,
          blockTimestamp: blockNumber,
        }),
      )
      source.getBlockHashesCalls->Utils.Array.clearInPlace
    }
    if source.getItemsOrThrowCalls->Array.length > 0 {
      source.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=301)
    }
    await Utils.delay(0)
  }
}

describe("Scenario rollback and history", () => {
  scenario->Scenario.it(
    "reverts an entity written after the rollback target",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      await enterThresholdAndIndex(~indexer, ~source)

      t.expect(
        await indexer.query("Counter"),
        ~message="the handler's write is committed before the reorg",
      ).toEqual([{id: "total", count: 1n}])

      // Block 300 comes back with a different hash, so everything after the
      // last valid block is rolled back — including the block-200 write.
      source.resolveGetHeightOrThrow(301)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=301,
        ~prevRangeLastBlock={blockNumber: 300, blockHash: "0x300a"},
      )

      // The depth search asks which blocks still hold. Only those up to 100 do,
      // so the rollback target is the checkpoint at block 100 and the block-200
      // write has no history at or before it — it's removed rather than restored.
      await driveRollback(~source, ~validUpTo=100)
      await indexer.waitUntilIdle()

      let counters: array<counter> = await indexer.query("Counter")
      t.expect(counters, ~message="the rolled-back write is gone").toEqual([])
    },
  )

  scenario->Scenario.it(
    "keeps a history row per committed change",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      await enterThresholdAndIndex(~indexer, ~source)

      let history: array<Change.t<counter>> = await indexer.queryHistory("Counter")
      t.expect(
        history->Array.map(
          change =>
            switch change {
            | Set({entityId, entity}) => (entityId->EntityId.toKey, Some(entity.count))
            | Delete({entityId}) => (entityId->EntityId.toKey, None)
            },
        ),
      ).toEqual([("total", Some(1n))])
    },
  )

  scenario->Scenario.it(
    "restores the pre-target value of an entity the rollback reverts",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      // Written below the reorg threshold, so it survives the rollback and is
      // what the reverted entity has to be restored to. The removal case above
      // never reaches the restore path, and a BigInt column is where the two
      // storages disagree about how a restored row is encoded.
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [setCounter(~block=50, ~count=1n)],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [setCounter(~block=200, ~count=2n)],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.query("Counter"),
        ~message="the post-threshold write is committed before the reorg",
      ).toEqual([{id: "total", count: 2n}])

      source.resolveGetHeightOrThrow(301)
      await MockSource.waitItemsQuery(source)
      source.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=301,
        ~prevRangeLastBlock={blockNumber: 300, blockHash: "0x300a"},
      )
      await driveRollback(~source, ~validUpTo=100)
      await indexer.waitUntilIdle()

      let counters: array<counter> = await indexer.query("Counter")
      t.expect(
        counters,
        ~message="the block-200 change is reverted to the value written at block 50",
      ).toEqual([{id: "total", count: 1n}])
    },
  )

  scenario->Scenario.it(
    "resumes from what the previous indexer persisted",
    ~sources=[{chain: 1, methods}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      await enterThresholdAndIndex(~indexer, ~source)

      let resumed = await indexer.restart()
      t.expect(
        await resumed.query("Counter"),
        ~message="the resumed indexer reads the entity the first one wrote",
      ).toEqual([{id: "total", count: 1n}])
    },
  )
})
