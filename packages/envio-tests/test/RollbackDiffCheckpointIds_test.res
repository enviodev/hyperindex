open Vitest

// The rollback stages a diff row per chain it moves, and stamps each with a
// checkpoint id. Under one shared sequence the ids of every chain come from a
// single counter, so "the first id after what this chain committed" is not an
// id of its own: two chains can be handed the same one, and a chain that
// committed behind its sibling is handed an id the sibling has already used.

type counter = {
  id: string,
  count: bigint,
  @as("chainId") chainId: int,
}

type counterOps = {set: {"id": string, "count": bigint} => unit}
type handlerContext = {
  @as("Counter") counter: counterOps,
  @as("Total") total: counterOps,
}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => handlerContext)

let chainYaml = chainId =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

// One cross-chain entity is what makes the checkpoint sequence shared, and what
// makes a reorg on either chain roll both of them back.
let scenario = Scenario.make(
  ~supervised=false,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}

type Total @crossChain {
  id: ID!
  count: BigInt!
}
`,
  ~configYaml=`
name: rollback-diff-checkpoint-ids
rollback_on_reorg: true
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainYaml(100)}${chainYaml(1337)}
`,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let setCounterAndTotal = (~block, ~count: bigint): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->asContext
    context.counter.set({"id": "total", "count": count})
    context.total.set({"id": "total", "count": count})
  },
}

// Installed by `mapStorage`, which is an argument to the test rather than part
// of its body — so the handle lives out here, where both can reach it.
let stagedDiffs: array<InternalTable.Checkpoints.diffCheckpoint> = []

describe("Rollback diff checkpoint ids", () => {
  scenario->Scenario.it(
    "Stamps each rolled-back chain's diff with an id of its own, above everything committed",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    ~mapStorage=storage => {
      ...storage,
      writeBatch: (
        ~batch,
        ~rollback,
        ~config,
        ~allEntities,
        ~updatedEffectsCache,
        ~updatedEntities,
        ~registeredAddresses,
        ~chainMetaData,
        ~onWrite,
      ) => {
        switch rollback {
        | Some({diffCheckpoints}) =>
          diffCheckpoints->Array.forEach(diff => stagedDiffs->Array.push(diff)->ignore)
        | None => ()
        }
        storage.writeBatch(
          ~batch,
          ~rollback,
          ~config,
          ~allEntities,
          ~updatedEffectsCache,
          ~updatedEntities,
          ~registeredAddresses,
          ~chainMetaData,
          ~onWrite,
        )
      },
    },
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await Utils.delay(0)
      let _ = await Promise.all2((
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=source100),
        Scenario.enterReorgThreshold(~t, ~indexer, ~source=source1337),
      ))

      // Chain 100 leads (the progress tie breaks by ascending chain id), so the
      // two chains take turns and commit different ids from the shared counter.
      await source100.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Respond({
            items: [setCounterAndTotal(~block=101, ~count=100n)],
            latestFetchedBlockNumber: 101,
          }),
        },
      ])
      await source1337.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Respond({
            items: [setCounterAndTotal(~block=101, ~count=1337n)],
            latestFetchedBlockNumber: 101,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      await source1337.expectItemsQueries([
        {
          fromBlock: 102,
          reply: Respond({
            items: [setCounterAndTotal(~block=102, ~count=13372n)],
            latestFetchedBlockNumber: 102,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await source100.expectItemsQueries([
        {
          fromBlock: 102,
          reply: Respond({
            items: [setCounterAndTotal(~block=102, ~count=1002n)],
            latestFetchedBlockNumber: 102,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      let highestCommitted =
        (await indexer.queryCheckpoints())->Array.reduce(0n, (highest, checkpoint) =>
          checkpoint.id > highest ? checkpoint.id : highest
        )

      // A reorg on chain 1337 at block 102 takes both chains back with it, so
      // the rollback stages a diff row for each of them.
      source100.dropPendingCalls()
      let reorgsBefore = source1337.reorgCallCount()
      await source1337.expectItemsQueries([
        {
          coversBlock: 103,
          reply: Respond({items: [], prevRangeLastBlock: {blockNumber: 102, blockHash: "0x102a"}}),
        },
        // The chunks fetched ahead of it go unanswered: the rollback refetches from 102.
        {partitionId: "0", reply: LeavePending},
      ])
      await Scenario.waitUntil(
        () => source1337.reorgCallCount() > reorgsBefore,
        ~message="the reorg to be detected and the rollback's depth search to start",
      )
      // The rollback's depth search re-fetches the scanned block hashes.
      await source1337.expectBlockHashLookup({
        blockNumbers: [100, 101],
        reply: [
          {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
          {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
        ],
      })
      await indexer.getRollbackReadyPromise()

      // The diff only reaches storage with the next batch, so chain 1337
      // re-delivers block 102 to flush it.
      await source1337.expectItemsQueries([
        {
          coversBlock: 102,
          reply: Respond({
            items: [setCounterAndTotal(~block=102, ~count=999n)],
            latestFetchedBlockNumber: 102,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      let sorted =
        stagedDiffs->Array.toSorted((a, b) =>
          a.checkpointId < b.checkpointId ? -1. : a.checkpointId > b.checkpointId ? 1. : 0.
        )
      t.expect(
        (
          stagedDiffs->Array.length,
          sorted->Array.every(diff => diff.checkpointId > highestCommitted),
          sorted->Array.everyWithIndex((diff, index) =>
            index === 0 || diff.checkpointId !== (sorted->Array.getUnsafe(index - 1)).checkpointId
          ),
          // The block number is read after every chain state has been rewound,
          // so a diff row never sits above the progress its chain stores with
          // it. A resume that found one there would call the row uncovered and
          // trim the diff away, un-reverting what the rollback reverted.
          sorted
          ->Array.toSorted((a, b) => ChainId.compare(a.chainId, b.chainId)->Int.toFloat)
          ->Array.map(diff => (diff.chainId->ChainId.toInt, diff.blockNumber)),
        ),
        ~message="Each rolled-back chain's diff gets its own id, above everything committed, stamped with the block the rollback left it on",
      ).toEqual((2, true, true, [(100, 101), (1337, 101)]))
    },
  )
})
