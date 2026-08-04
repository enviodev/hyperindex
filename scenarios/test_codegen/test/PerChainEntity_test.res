open Vitest

// Same entity id on two chains. Under `disable_default_cross_chain` it must
// resolve to two independent Postgres rows; the @crossChain one stays single.
type counter = {
  id: string,
  count: bigint,
  @as("chainId") chainId: int,
}
type globalCounter = {
  id: string,
  count: bigint,
}

type counterOps = {set: {"id": string, "count": bigint} => unit}
type handlerContext = {
  @as("Counter") counter: counterOps,
  @as("GlobalCounter") globalCounter: counterOps,
}

let configYaml = `
name: per-chain
disable_default_cross_chain: true
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
        address: "0x0000000000000000000000000000000000000001"
  - id: 137
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
type GlobalCounter @crossChain {
  id: ID!
  count: BigInt!
}
`

// One event per chain, both bumping the id "total".
let bump = (count: bigint): MockIndexer.Source.itemMock => {
  blockNumber: 5,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: MockIndexer.handlerContext => handlerContext)
    context.counter.set({"id": "total", "count": count})
    context.globalCounter.set({"id": "total", "count": count})
  },
}

let setEntities = (~block, ~counter: bigint): MockIndexer.Source.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: MockIndexer.handlerContext => handlerContext)
    context.counter.set({"id": "total", "count": counter})
  },
}

describe("Per-chain entities against Postgres", () => {
  Async.it("Writes one row per chain and a single row for @crossChain", async t => {
    let {config} = InternalTestIndexer.fromUserApi(~schema, ~configYaml)

    let source1 = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chainId=#1)
    let source137 = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chainId=#137)
    let indexerMock = await MockIndexer.Indexer.make(
      ~config,
      ~chains=[
        {chain: #1, sourceConfig: Config.CustomSources([source1.source])},
        {chain: #137, sourceConfig: Config.CustomSources([source137.source])},
      ],
      ~shouldRollbackOnReorg=false,
    )
    await Utils.delay(0)

    source1.resolveGetHeightOrThrow(300)
    source137.resolveGetHeightOrThrow(300)
    await Utils.delay(0)
    await Utils.delay(0)

    source1.resolveGetItemsOrThrow([bump(1n)], ~latestFetchedBlockNumber=300)
    source137.resolveGetItemsOrThrow([bump(10n)], ~latestFetchedBlockNumber=300)
    await indexerMock.getBatchWritePromise()
    await indexerMock.waitUntilIdle()

    let counters: array<counter> = await indexerMock.queryRaw(
      config.userEntitiesByName->Dict.getUnsafe("Counter"),
    )
    let globals: array<globalCounter> = await indexerMock.queryRaw(
      config.userEntitiesByName->Dict.getUnsafe("GlobalCounter"),
    )

    await indexerMock.stop()

    t.expect((
      counters->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId)),
      globals,
    )).toEqual((
      [{id: "total", count: 1n, chainId: 1}, {id: "total", count: 10n, chainId: 137}],
      [{id: "total", count: 10n}],
    ))
  })
})

describe("Chain-scoped rollback", () => {
  // A reorg rolls every chain back to a consistent checkpoint, so what has to
  // be per-chain is the restore itself: the same entity id on two chains must
  // be reverted (or left alone) independently.
  Async.it("Restores each chain's row from its own history", async t => {
    let {config} = InternalTestIndexer.fromUserApi(~schema, ~configYaml)

    let source1 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#1,
    )
    let source137 = MockIndexer.Source.make(
      [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
      ~chainId=#137,
    )
    let indexerMock = await MockIndexer.Indexer.make(
      ~config,
      ~chains=[
        {chain: #1, sourceConfig: Config.CustomSources([source1.source]), maxReorgDepth: 200},
        {chain: #137, sourceConfig: Config.CustomSources([source137.source]), maxReorgDepth: 200},
      ],
    )
    await Utils.delay(0)

    let _ = await Promise.all2((
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=source137),
      MockIndexer.Helper.initialEnterReorgThreshold(~t, ~indexerMock, ~sourceMock=source1),
    ))

    // Chain 137 writes the shared id first, then chain 1 — so chain 137's row
    // sits below the checkpoint chain 1 will roll back to.
    source137.resolveGetItemsOrThrow(
      [setEntities(~block=101, ~counter=137n)],
      ~latestFetchedBlockNumber=101,
      ~latestFetchedBlockHash="0x101",
    )
    await indexerMock.getBatchWritePromise()
    source1.resolveGetItemsOrThrow(
      [setEntities(~block=101, ~counter=1n)],
      ~latestFetchedBlockNumber=101,
      ~latestFetchedBlockHash="0x101",
    )
    await indexerMock.getBatchWritePromise()

    // Chain 1 overwrites its row at block 102, which is the change the reorg
    // takes back.
    source1.resolveGetItemsOrThrow(
      [setEntities(~block=102, ~counter=2n)],
      ~latestFetchedBlockNumber=102,
      ~latestFetchedBlockHash="0x102",
    )
    await indexerMock.getBatchWritePromise()

    // Block 102 comes back with a different hash.
    source1.resolveGetItemsOrThrow(
      [setEntities(~block=103, ~counter=99n)],
      ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102-reorged"},
    )
    await Utils.delay(0)
    await Utils.delay(0)

    source1.resolveGetBlockHashes([
      {blockNumber: 101, blockHash: "0x101", blockTimestamp: 101},
    ])
    await indexerMock.getRollbackReadyPromise()

    // The rollback diff is written with the next batch, so drive chain 1 once
    // more (with nothing to index) to flush it.
    source1.resolveGetItemsOrThrow(
      [],
      ~latestFetchedBlockNumber=102,
      ~latestFetchedBlockHash="0x102",
    )
    await indexerMock.getBatchWritePromise()
    await indexerMock.waitUntilIdle()

    let counters: array<counter> = await indexerMock.queryRaw(
      config.userEntitiesByName->Dict.getUnsafe("Counter"),
    )

    await indexerMock.stop()

    t.expect(counters->Array.toSorted((a, b) => Int.compare(a.chainId, b.chainId))).toEqual([
      {id: "total", count: 1n, chainId: 1},
      {id: "total", count: 137n, chainId: 137},
    ])
  })
})
