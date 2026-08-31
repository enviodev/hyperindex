open Vitest

// A schema with no cross-chain entity means a reorg on one chain can never have
// changed a row another chain owns. The rollback then stays isolated to the
// reorg chain: every sibling keeps its progress, entities, history and
// checkpoints, and is never asked to re-index a block it already processed.

type counter = {
  id: string,
  count: bigint,
  @as("chainId") chainId: int,
}
type total = {id: string, count: bigint}

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

let makeConfigYaml = (~name, ~extra="") =>
  `
name: ${name}
rollback_on_reorg: true
disable_default_cross_chain: true${extra}
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainYaml(100)}${chainYaml(1337)}
`

let perChainSchema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let scenario = Scenario.make(
  ~schema=perChainSchema,
  ~configYaml=makeConfigYaml(~name="isolated-rollback"),
)

// One cross-chain entity is enough to couple the chains: a value chain 1337
// wrote can be what chain 100 read and overwrote, so its reorg has to take
// every chain back with it.
let crossChainScenario = Scenario.make(
  ~schema=perChainSchema ++ `
type Total @crossChain {
  id: ID!
  count: BigInt!
}
`,
  ~configYaml=makeConfigYaml(~name="isolated-rollback-cross-chain"),
)

// The sink is append-only: an isolated rollback reaches it as the diff rows the
// next batch carries, and its current-state view has to resolve to the same
// thing Postgres holds.
let clickHouseScenario = Scenario.make(
  ~schema=perChainSchema,
  ~configYaml=makeConfigYaml(~name="isolated-rollback-clickhouse"),
  ~unsupported=[{backend: #postgres, reason: "asserts against a ClickHouse server"}],
)

let fullHistoryScenario = Scenario.make(
  ~schema=perChainSchema,
  ~configYaml=makeConfigYaml(
    ~name="isolated-rollback-full-history",
    ~extra="\nsave_full_history: true",
  ),
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let setCounter = (~block, ~count: bigint): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->asContext
    context.counter.set({"id": "total", "count": count})
  },
}

let setCounterAndTotal = (~block, ~count: bigint): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->asContext
    context.counter.set({"id": "total", "count": count})
    context.total.set({"id": "total", "count": count})
  },
}

let progressByChain = async (indexer: IndexerRunner.t) => {
  let metrics = await indexer.metric("envio_progress_block")
  metrics->Array.toSorted((a: IndexerRunner.metric, b) =>
    String.compare(
      a.labels->Dict.get("chainId")->Option.getOr(""),
      b.labels->Dict.get("chainId")->Option.getOr(""),
    )
  )
}

let counters = (indexer: IndexerRunner.t): promise<array<counter>> => indexer.query("Counter")
let counterHistory = (indexer: IndexerRunner.t): promise<array<Change.t<counter>>> =>
  indexer.queryHistory("Counter")

// Brings both chains into the reorg threshold and up to block 102, with chain
// 1337 writing block 102 first — so chain 100's block-102 checkpoint carries a
// higher id than the chain-1337 rows a reorg on 1337 has to delete.
let driveBothChainsToBlock102 = async (
  ~t,
  ~indexer: IndexerRunner.t,
  ~source100: MockSource.t,
  ~source1337: MockSource.t,
  ~item: (~block: int, ~count: bigint) => MockSource.itemMock,
) => {
  await Utils.delay(0)
  let _ = await Promise.all2((
    Scenario.enterReorgThreshold(~t, ~indexer, ~source=source100),
    Scenario.enterReorgThreshold(~t, ~indexer, ~source=source1337),
  ))

  // Chain 100 leads (the progress tie breaks by ascending chain id), so its
  // post-threshold query is the one holding the fetch budget.
  source100.resolveGetItemsOrThrow([item(~block=101, ~count=100n)], ~latestFetchedBlockNumber=101)
  await MockSource.waitItemsQuery(source1337)
  source1337.resolveGetItemsOrThrow([item(~block=101, ~count=1337n)], ~latestFetchedBlockNumber=101)
  await indexer.getBatchWritePromise()

  source1337.resolveGetItemsOrThrow(
    [item(~block=102, ~count=13372n)],
    ~latestFetchedBlockNumber=102,
  )
  await indexer.getBatchWritePromise()
  source100.resolveGetItemsOrThrow([item(~block=102, ~count=1002n)], ~latestFetchedBlockNumber=102)
  await indexer.getBatchWritePromise()
}

// Reorgs `source` at block 102: the range covering 103 comes back reporting a
// different hash for 102, and blocks 100 and 101 survive the depth search.
//
// The rollback resets every chain's in-flight queries, so the sibling's are
// voided in the mock first — otherwise its pre-rollback queries stay pending
// there and the ones it re-issues can't be told apart from them.
let reorgAtBlock102 = async (
  ~indexer: IndexerRunner.t,
  ~source: MockSource.t,
  ~sibling: MockSource.t,
) => {
  sibling.dropPendingCalls()
  source.resolveGetItemsOrThrow(
    [],
    ~filter=MockSource.coveringBlock(103),
    ~prevRangeLastBlock={blockNumber: 102, blockHash: "0x102a"},
  )
  await Utils.delay(0)
  await Utils.delay(0)
  source.resolveGetBlockHashes([
    {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
    {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
  ])
  await indexer.getRollbackReadyPromise()
}

// The rollback diff only reaches the database with the next batch, so the reorg
// chain re-delivers block 102 to flush it.
let reindexBlock102 = async (~indexer: IndexerRunner.t, ~source: MockSource.t, ~count) => {
  source.resolveGetItemsOrThrow(
    [setCounter(~block=102, ~count)],
    ~filter=MockSource.coveringBlock(102),
    ~latestFetchedBlockNumber=102,
  )
  await indexer.getBatchWritePromise()
}

let blockHash = blockNumber => Js.Null.Value(MockSource.evmBlockHash(`0x0${blockNumber}`))

describe("Isolated multichain rollback", () => {
  // The diff rides on the next batch whatever produced it, and a sibling that
  // never stopped indexing produces one long before the reorg chain has
  // re-fetched anything. That batch has no progress of its own for the reorg
  // chain, so the rollback has to carry it: otherwise the chain's stored
  // progress outlives the checkpoints backing it, and a restart resumes past
  // blocks it never re-indexed.
  scenario->Scenario.it(
    "Persists the rolled-back progress when a sibling's batch carries the diff",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(~t, ~indexer, ~source100, ~source1337, ~item=setCounter)
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)

      // Only chain 100 progresses, so its batch is what carries the diff.
      source100.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(103),
        ~latestFetchedBlockNumber=104,
      )
      await indexer.getBatchWritePromise()

      source100.setAutoHeight(300)
      source1337.setAutoHeight(300)
      let restarted = await indexer.restart()
      await Utils.delay(0)
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        (
          await Promise.all2((counters(restarted), progressByChain(restarted))),
          source1337.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
          source100.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ),
        ~message="Chain 1337 resumes at the block the rollback took it back to",
      ).toEqual((
        (
          [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 1337n, chainId: 1337}],
          [
            {value: "104", labels: Dict.fromArray([("chainId", "100")])},
            {value: "101", labels: Dict.fromArray([("chainId", "1337")])},
          ],
        ),
        [102],
        [105],
      ))
    },
  )

  // Same write, with the reorg chain's sibling rolled back too: it is in the
  // rollback's progress rows *and* in the batch's, so the batch's later value
  // has to be the one that stands.
  crossChainScenario->Scenario.it(
    "Lets a batch's own progress win over the rollback's for the same chain",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(
        ~t,
        ~indexer,
        ~source100,
        ~source1337,
        ~item=setCounterAndTotal,
      )
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)

      // The global rollback took chain 100 back to 101 as well; it re-fetches
      // past that before chain 1337 gets anywhere, and carries the diff.
      source100.resolveGetItemsOrThrow(
        [],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=104,
      )
      await indexer.getBatchWritePromise()

      source100.setAutoHeight(300)
      source1337.setAutoHeight(300)
      let restarted = await indexer.restart()
      await Utils.delay(0)
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        (
          await progressByChain(restarted),
          source1337.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
          source100.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ),
        ~message="Chain 100 resumes from what its batch reached, chain 1337 from where the rollback left it",
      ).toEqual((
        [
          {value: "104", labels: Dict.fromArray([("chainId", "100")])},
          {value: "101", labels: Dict.fromArray([("chainId", "1337")])},
        ],
        [102],
        [105],
      ))
    },
  )

  scenario->Scenario.it(
    "Rolls back the reorg chain alone and leaves its sibling untouched",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(~t, ~indexer, ~source100, ~source1337, ~item=setCounter)

      t.expect(
        await Promise.all4((
          indexer.queryCheckpoints(),
          counters(indexer),
          counterHistory(indexer),
          progressByChain(indexer),
        )),
        ~message="Both chains reached block 102, with their checkpoints interleaved",
      ).toEqual((
        [
          {
            id: 3n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 4n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 5n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
          {
            id: 6n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
        ],
        [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 13372n, chainId: 1337}],
        [
          Set({
            checkpointId: 3n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 100n, chainId: 100},
          }),
          Set({
            checkpointId: 4n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1337n, chainId: 1337},
          }),
          Set({
            checkpointId: 5n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 13372n, chainId: 1337},
          }),
          Set({
            checkpointId: 6n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1002n, chainId: 100},
          }),
        ],
        [
          {value: "102", labels: Dict.fromArray([("chainId", "100")])},
          {value: "102", labels: Dict.fromArray([("chainId", "1337")])},
        ],
      ))

      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)

      t.expect(
        (
          await progressByChain(indexer),
          // The lowest block chain 100 is asked for once it re-issues the
          // queries the rollback dropped: it kept block 102, so it never goes
          // back below 103.
          source100.getItemsOrThrowCalls
          ->Array.map(call => call.payload["fromBlock"])
          ->Array.toSorted(Int.compare)
          ->Array.get(0),
        ),
        ~message="Only chain 1337 lost progress",
      ).toEqual((
        [
          {value: "102", labels: Dict.fromArray([("chainId", "100")])},
          {value: "101", labels: Dict.fromArray([("chainId", "1337")])},
        ],
        Some(103),
      ))

      await reindexBlock102(~indexer, ~source=source1337, ~count=999n)

      t.expect(
        await Promise.all4((
          indexer.queryCheckpoints(),
          counters(indexer),
          counterHistory(indexer),
          progressByChain(indexer),
        )),
        ~message="Chain 1337 re-indexed above chain 100's untouched rows",
      ).toEqual((
        [
          {
            id: 3n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 4n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 6n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
          {
            id: 8n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
        ],
        [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [
          Set({
            checkpointId: 3n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 100n, chainId: 100},
          }),
          Set({
            checkpointId: 4n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1337n, chainId: 1337},
          }),
          Set({
            checkpointId: 6n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1002n, chainId: 100},
          }),
          Set({
            checkpointId: 8n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 999n, chainId: 1337},
          }),
        ],
        [
          {value: "102", labels: Dict.fromArray([("chainId", "100")])},
          {value: "102", labels: Dict.fromArray([("chainId", "1337")])},
        ],
      ))
    },
  )

  crossChainScenario->Scenario.it(
    "Falls back to a global rollback when one entity is cross-chain",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(
        ~t,
        ~indexer,
        ~source100,
        ~source1337,
        ~item=setCounterAndTotal,
      )
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)

      // Chain 100 has to give back block 102 as well: its own write to `Total`
      // sat on top of the chain-1337 write the reorg took away.
      t.expect(
        (
          await progressByChain(indexer),
          source100.getItemsOrThrowCalls->Array.some(call => call.payload["fromBlock"] === 102),
        ),
        ~message="Both chains lost block 102",
      ).toEqual((
        [
          {value: "101", labels: Dict.fromArray([("chainId", "100")])},
          {value: "101", labels: Dict.fromArray([("chainId", "1337")])},
        ],
        true,
      ))

      source100.resolveGetItemsOrThrow(
        [setCounterAndTotal(~block=102, ~count=1002n)],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()
      source1337.resolveGetItemsOrThrow(
        [setCounterAndTotal(~block=102, ~count=999n)],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await Promise.all3((
          indexer.queryCheckpoints(),
          counters(indexer),
          (indexer.query("Total"): promise<array<total>>),
        )),
        ~message="Every checkpoint above the target went, on both chains",
      ).toEqual((
        [
          {
            id: 3n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 4n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 8n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
          {
            id: 9n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
        ],
        [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [{id: "total", count: 999n}],
      ))
    },
  )

  // The second rollback's target sits below checkpoints the first one's chain
  // has since re-indexed. Deleting by checkpoint id alone would take those with
  // it; only the reorg chain's rows may go.
  scenario->Scenario.it(
    "Keeps a sibling's re-indexed rows when a later reorg targets a lower checkpoint",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(~t, ~indexer, ~source100, ~source1337, ~item=setCounter)
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)
      await reindexBlock102(~indexer, ~source=source1337, ~count=999n)

      await reorgAtBlock102(~indexer, ~source=source100, ~sibling=source1337)
      await reindexBlock102(~indexer, ~source=source100, ~count=1003n)

      t.expect(
        await Promise.all4((
          indexer.queryCheckpoints(),
          counters(indexer),
          counterHistory(indexer),
          progressByChain(indexer),
        )),
        ~message="Chain 1337's re-indexed rows outlived chain 100's rollback to a lower checkpoint",
      ).toEqual((
        [
          {
            id: 3n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 4n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 8n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
          {
            id: 10n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
        ],
        [{id: "total", count: 1003n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [
          Set({
            checkpointId: 3n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 100n, chainId: 100},
          }),
          Set({
            checkpointId: 4n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1337n, chainId: 1337},
          }),
          Set({
            checkpointId: 8n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 999n, chainId: 1337},
          }),
          Set({
            checkpointId: 10n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1003n, chainId: 100},
          }),
        ],
        [
          {value: "102", labels: Dict.fromArray([("chainId", "100")])},
          {value: "102", labels: Dict.fromArray([("chainId", "1337")])},
        ],
      ))
    },
  )

  // Two isolated rollbacks can't be merged: the second diff replaces the first,
  // and its deletes only reach its own chain. Widening to a global rollback is
  // what keeps the first one's rows from being stranded above their target.
  scenario->Scenario.it(
    "Widens to a global rollback when a second reorg lands before the first is written",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(~t, ~indexer, ~source100, ~source1337, ~item=setCounter)

      // No batch progresses in between, so the first diff is still unwritten
      // when the second reorg computes its own.
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)
      await reorgAtBlock102(~indexer, ~source=source100, ~sibling=source1337)

      t.expect(
        await progressByChain(indexer),
        ~message="Both chains went back past the lower of the two targets",
      ).toEqual([
        {value: "101", labels: Dict.fromArray([("chainId", "100")])},
        {value: "100", labels: Dict.fromArray([("chainId", "1337")])},
      ])

      source100.resolveGetItemsOrThrow(
        [setCounter(~block=102, ~count=1003n)],
        ~filter=MockSource.coveringBlock(102),
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()
      source1337.resolveGetItemsOrThrow(
        [setCounter(~block=101, ~count=1337n), setCounter(~block=102, ~count=999n)],
        ~filter=MockSource.coveringBlock(101),
        ~latestFetchedBlockNumber=102,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await Promise.all3((
          indexer.queryCheckpoints(),
          counters(indexer),
          counterHistory(indexer),
        )),
        ~message="Nothing above the lower target survived on either chain",
      ).toEqual((
        [
          {
            id: 3n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 8n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
          {
            id: 9n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 10n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
        ],
        [{id: "total", count: 1003n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [
          Set({
            checkpointId: 3n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 100n, chainId: 100},
          }),
          Set({
            checkpointId: 8n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1003n, chainId: 100},
          }),
          Set({
            checkpointId: 9n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1337n, chainId: 1337},
          }),
          Set({
            checkpointId: 10n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 999n, chainId: 1337},
          }),
        ],
      ))
    },
  )

  scenario->Scenario.it(
    "Resumes from the checkpoints an isolated rollback left behind",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(~t, ~indexer, ~source100, ~source1337, ~item=setCounter)
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)
      await reindexBlock102(~indexer, ~source=source1337, ~count=999n)

      source100.setAutoHeight(300)
      source1337.setAutoHeight(300)
      let restarted = await indexer.restart()
      await Utils.delay(0)
      await Utils.delay(0)
      await Utils.delay(0)

      t.expect(
        (
          await Promise.all2((counters(restarted), progressByChain(restarted))),
          source100.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
          source1337.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ),
        ~message="Both chains resume from block 103 with their rows intact",
      ).toEqual((
        (
          [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
          [
            {value: "102", labels: Dict.fromArray([("chainId", "100")])},
            {value: "102", labels: Dict.fromArray([("chainId", "1337")])},
          ],
        ),
        [103],
        [103],
      ))
    },
  )

  fullHistoryScenario->Scenario.it(
    "Keeps the sibling's full history when save_full_history is on",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(~t, ~indexer, ~source100, ~source1337, ~item=setCounter)
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)
      await reindexBlock102(~indexer, ~source=source1337, ~count=999n)

      t.expect(
        await Promise.all3((
          counterHistory(indexer),
          counters(indexer),
          indexer.queryCheckpoints(),
        )),
        ~message="Chain 100 kept every history row and checkpoint it ever wrote",
      ).toEqual((
        [
          Set({
            checkpointId: 3n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 100n, chainId: 100},
          }),
          Set({
            checkpointId: 4n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1337n, chainId: 1337},
          }),
          Set({
            checkpointId: 6n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 1002n, chainId: 100},
          }),
          Set({
            checkpointId: 8n,
            entityId: "total"->EntityId.unsafeOfString,
            entity: {id: "total", count: 999n, chainId: 1337},
          }),
        ],
        [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [
          {
            id: 1n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 100,
            blockHash: blockHash("100"),
            eventsProcessed: 0,
          },
          {
            id: 2n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 100,
            blockHash: blockHash("100"),
            eventsProcessed: 0,
          },
          {
            id: 3n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 4n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 101,
            blockHash: blockHash("101"),
            eventsProcessed: 1,
          },
          {
            id: 6n,
            chainId: 100->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
          {
            id: 8n,
            chainId: 1337->ChainId.fromInt,
            blockNumber: 102,
            blockHash: blockHash("102"),
            eventsProcessed: 1,
          },
        ],
      ))
    },
  )

  clickHouseScenario->Scenario.it(
    "Mirrors the isolated rollback into the ClickHouse sink",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(~t, ~indexer, ~source100, ~source1337, ~item=setCounter)
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)
      await reindexBlock102(~indexer, ~source=source1337, ~count=999n)
      await indexer.waitUntilIdle()

      let database = TestClickHouse.currentDatabase()
      t.expect(
        (
          await TestClickHouse.query(
            `SELECT id, count, chainId FROM \`${database}\`.\`Counter\` ORDER BY chainId FORMAT JSONEachRow`,
          )
        )->String.trim,
        ~message="The view resolves chain 100's untouched row and chain 1337's re-indexed one",
      ).toEqual(`{"id":"total","count":"1002","chainId":100}
{"id":"total","count":"999","chainId":1337}`)
    },
  )
})
