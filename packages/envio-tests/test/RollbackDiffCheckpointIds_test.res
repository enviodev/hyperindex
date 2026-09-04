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
let diffCheckpointIds: array<bigint> = []

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
          diffCheckpoints->Array.forEach(diff =>
            diffCheckpointIds->Array.push(diff.checkpointId)->ignore
          )
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
      source100.resolveGetItemsOrThrow(
        [setCounterAndTotal(~block=101, ~count=100n)],
        ~latestFetchedBlockNumber=101,
      )
      await MockSource.waitItemsQuery(source1337)
      source1337.resolveGetItemsOrThrow(
        [setCounterAndTotal(~block=101, ~count=1337n)],
        ~latestFetchedBlockNumber=101,
      )
      await indexer.getBatchWritePromise()

      source1337.resolveGetItemsOrThrow(
        [setCounterAndTotal(~block=102, ~count=13372n)],
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()
      source100.resolveGetItemsOrThrow(
        [setCounterAndTotal(~block=102, ~count=1002n)],
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()

      let highestCommitted =
        (await indexer.queryCheckpoints())
        ->Array.reduce(0n, (highest, checkpoint) =>
          checkpoint.id > highest ? checkpoint.id : highest
        )

      // A reorg on chain 1337 at block 102 takes both chains back with it, so
      // the rollback stages a diff row for each of them.
      source100.dropPendingCalls()
      let reorgsBefore = source1337.reorgCallCount()
      source1337.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(103),
        ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102a"},
      )
      await Scenario.waitUntil(
        () => source1337.reorgCallCount() > reorgsBefore,
        ~message="the reorg to be detected and the rollback's depth search to start",
      )
      await Scenario.waitUntil(
        () => source1337.getBlockHashesCalls->Array.length > 0,
        ~message="the rollback's depth search to re-fetch the scanned block hashes",
      )
      source1337.resolveGetBlockHashes(
        [(100, "0x100"), (101, "0x101")]->Array.map(((blockNumber, blockHash)): BlockStore.inputBlock => {
          blockNumber,
          blockHash,
          blockTimestamp: blockNumber,
        }),
      )
      await indexer.getRollbackReadyPromise()

      // The diff only reaches storage with the next batch, so chain 1337
      // re-delivers block 102 to flush it.
      source1337.resolveGetItemsOrThrow(
        [setCounterAndTotal(~block=102, ~count=999n)],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()

      let sorted = diffCheckpointIds->Array.toSorted((a, b) => a < b ? -1. : a > b ? 1. : 0.)
      t.expect(
        (
          diffCheckpointIds->Array.length,
          sorted->Array.every(id => id > highestCommitted),
          sorted->Array.everyWithIndex((id, index) => index === 0 || id !== sorted->Array.getUnsafe(index - 1)),
        ),
        ~message="Each rolled-back chain's diff gets its own id, and every one of them outranks everything already committed",
      ).toEqual((2, true, true))
    },
  )
})
