open Vitest

// A checkpoint a reorg can no longer reach is pruned, with or without an entity
// whose history Postgres prunes beside it.

type counterOps = {set: {"id": string, "count": bigint} => unit}
type handlerContext = {@as("Counter") counter: counterOps}

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let configYaml = `
name: checkpoint-prune
rollback_on_reorg: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 100
    rpc:
      url: https://rpc100.example.test
      for: sync
    start_block: 110
    max_reorg_depth: 15
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`

let scenario = Scenario.make(~supervised=false, ~schema, ~configYaml)

let setCounter = (~block, ~count): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    (args.context->(Utils.magic: Internal.handlerContext => handlerContext)).counter.set({
      "id": "total",
      "count": count,
    }),
}

let dropsTheUnreachableCheckpoints = async (
  ~t: Vitest.testContext,
  ~indexer,
  ~source: (int, ~index: int=?) => MockSource.t,
) => {
  let source = source(100)
  await Scenario.resolveInitialHeight(~t, ~source, ~head=120)
  source.resolveGetItemsOrThrow(
    [setCounter(~block=111, ~count=1n), setCounter(~block=112, ~count=2n)],
    ~latestFetchedBlockNumber=112,
  )
  await indexer.IndexerRunner.getBatchWritePromise()
  // Block 115 is now safe: 111 and 112 fall out of reach, 112 staying as the
  // anchor of what is above it.
  source.setAutoHeight(130)
  source.resolveGetItemsOrThrow(
    [setCounter(~block=120, ~count=3n)],
    ~filter=MockSource.coveringBlock(113),
    ~latestFetchedBlockNumber=130,
  )
  await indexer.getBatchWritePromise()
  await indexer.waitUntilIdle()

  t.expect(
    (await indexer.queryCheckpoints())->Array.map(({id, blockNumber}) => (id, blockNumber)),
  ).toEqual([(2n, 112), (3n, 120), (4n, 130)])
}

let sources: array<Scenario.sourceMock> = [
  {chain: 100, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
]

describe("Checkpoint pruning", () => {
  scenario->Scenario.it(
    "Drops the checkpoints below the chain's safe one",
    ~sources,
    ~reorgThresholdReadyTolerance=0,
    dropsTheUnreachableCheckpoints,
  )
})
