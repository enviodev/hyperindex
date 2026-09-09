open Vitest

// A chain with no reorg depth can never be rolled back, so nothing it writes
// needs history — and with no history to anchor, no checkpoints either. The
// reorg threshold it enters immediately (its pre-threshold lag is zero) says
// nothing about that.

type counter = {
  id: string,
  count: bigint,
}

type counterOps = {set: {"id": string, "count": bigint} => unit}
type handlerContext = {@as("Counter") counter: counterOps}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => handlerContext)

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let chainYaml = (chainId, ~maxReorgDepth) =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    max_reorg_depth: ${maxReorgDepth->Int.toString}
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

// One chain, and the default cross-chain entities that make its checkpoint
// sequence a shared one.
let singleChainScenario = Scenario.make(
  ~schema,
  ~configYaml=`
name: zero-reorg-depth-history
rollback_on_reorg: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainYaml(100, ~maxReorgDepth=0)}
`,
)

// No cross-chain entity, so each chain counts its own checkpoints and only the
// chain that can be rolled back keeps any.
let perChainScenario = Scenario.make(
  ~schema,
  ~configYaml=`
name: zero-reorg-depth-history-per-chain
rollback_on_reorg: true
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainYaml(100, ~maxReorgDepth=200)}${chainYaml(1337, ~maxReorgDepth=0)}
`,
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let setCounter = (~block, ~count: bigint): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    (args.context->asContext).counter.set({"id": "total", "count": count})
  },
}

let checkpointChains = async (indexer: IndexerRunner.t) =>
  (await indexer.queryCheckpoints())
  ->Array.map(({chainId}) => chainId->ChainId.toInt)
  ->Array.toSorted((a, b) => (a - b)->Int.toFloat)

describe("A chain with no reorg depth keeps no history", () => {
  singleChainScenario->Scenario.it(
    "Writes neither history nor checkpoints for the only chain, past the threshold",
    ~sources=[{chain: 100, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      await Scenario.resolveInitialHeight(~t, ~source=source100, ~head=120)

      source100.resolveGetItemsOrThrow(
        [setCounter(~block=110, ~count=1n), setCounter(~block=111, ~count=2n)],
        ~latestFetchedBlockNumber=120,
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      let history: array<Change.t<counter>> = await indexer.queryHistory("Counter")
      t.expect(
        (
          await indexer.metric("envio_reorg_threshold"),
          history->Array.length,
          (await indexer.queryCheckpoints())->Array.length,
        ),
        ~message="A chain no rollback can reach writes no history, and no checkpoints to anchor it",
      ).toEqual(([{IndexerRunner.value: "1", labels: Dict.make()}], 0, 0))
    },
  )

  perChainScenario->Scenario.it(
    "Keeps checkpoints only for the chain that can be rolled back",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)
      await Utils.delay(0)
      let _ = await Promise.all2((
        Scenario.resolveInitialHeight(~t, ~source=source100, ~head=300),
        Scenario.resolveInitialHeight(~t, ~source=source1337, ~head=300),
      ))

      // Chain 100 is held 200 blocks below the head until it reaches block 100,
      // which is what takes the indexer into the reorg threshold. Chain 1337 has
      // no depth to lag by and fetches to the head at once.
      source100.resolveGetItemsOrThrow(
        [setCounter(~block=50, ~count=1n)],
        ~latestFetchedBlockNumber=100,
      )
      source1337.resolveGetItemsOrThrow(
        [setCounter(~block=50, ~count=2n)],
        ~latestFetchedBlockNumber=300,
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      // A second batch on both chains. The stale-history prune is throttled to
      // one run per interval, so whatever this batch writes is still there.
      source1337.setAutoHeight(400)
      source100.resolveGetItemsOrThrow(
        [setCounter(~block=150, ~count=3n)],
        ~filter=MockSource.coveringBlock(101),
        ~latestFetchedBlockNumber=300,
      )
      source1337.resolveGetItemsOrThrow(
        [setCounter(~block=350, ~count=4n)],
        ~filter=MockSource.coveringBlock(301),
        ~latestFetchedBlockNumber=400,
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      t.expect(
        await checkpointChains(indexer),
        ~message="Only the chain a rollback can reach gets checkpoints",
      ).toEqual([100, 100])
    },
  )
})
