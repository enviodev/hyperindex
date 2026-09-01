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

// Per-chain metrics come back in no particular order, so every read is sorted
// by the chain label the assertions are written in.
let metricByChain = async (indexer: IndexerRunner.t, name) => {
  let metrics = await indexer.metric(name)
  metrics->Array.toSorted((a: IndexerRunner.metric, b) =>
    String.compare(
      a.labels->Dict.get("chainId")->Option.getOr(""),
      b.labels->Dict.get("chainId")->Option.getOr(""),
    )
  )
}

let progressByChain = indexer => indexer->metricByChain("envio_progress_block")
let eventsByChain = indexer => indexer->metricByChain("envio_progress_events")

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

// Reorgs `source` at `atBlock`: the range above it comes back reporting a
// different hash, and the depth search re-fetches `scanned` — the blocks the
// chain still has hashes for. A block listed as `#valid` answers with the hash
// already stored and `#orphaned` with a different one, so the rollback targets
// the highest valid block among them.
//
// A rollback that reaches `sibling` resets its in-flight queries, so those are
// voided in the mock first — otherwise its pre-rollback queries stay pending
// there and the ones it re-issues can't be told apart from them. An isolated
// rollback leaves the sibling indexing, and passes no `sibling` to void.
let reorgAt = async (
  ~indexer: IndexerRunner.t,
  ~source: MockSource.t,
  ~sibling: option<MockSource.t>=?,
  ~atBlock,
  ~scanned: array<(int, [#valid | #orphaned])>=[],
) => {
  sibling->Option.forEach(sibling => sibling.dropPendingCalls())
  let reorgsBefore = source.reorgCallCount()
  source.resolveGetItemsOrThrow(
    [],
    ~filter=MockSource.coveringBlock(atBlock + 1),
    ~prevRangeLastBlock={blockNumber: atBlock, blockHash: `0x${atBlock->Int.toString}a`},
  )
  // The depth search drops the source's orphaned-chain state before it reads
  // any hash, so this is the one point both shapes of the search pass through —
  // and the only thing separating "the rollback hasn't started" from "there is
  // no rollback" for a search that never asks for a hash at all.
  await Scenario.waitUntil(
    () => source.reorgCallCount() > reorgsBefore,
    ~message="the reorg to be detected and the rollback's depth search to start",
  )

  // With nothing left hashed inside the threshold the search skips the lookup
  // and falls straight back to the threshold's lower edge, so an empty
  // `scanned` waits for no call.
  if scanned->Array.length > 0 {
    await Scenario.waitUntil(
      () => source.getBlockHashesCalls->Array.length > 0,
      ~message="the rollback's depth search to re-fetch the scanned block hashes",
    )
    source.resolveGetBlockHashes(
      scanned->Array.map(((blockNumber, fate)): BlockStore.inputBlock => {
        blockNumber,
        blockHash: switch fate {
        | #valid => `0x${blockNumber->Int.toString}`
        | #orphaned => `0x${blockNumber->Int.toString}a`
        },
        blockTimestamp: blockNumber,
      }),
    )
  }
  await indexer.getRollbackReadyPromise()
}

let reorgAtBlock102 = (~indexer, ~source, ~sibling) =>
  reorgAt(~indexer, ~source, ~sibling, ~atBlock=102, ~scanned=[(100, #valid), (101, #valid)])

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

// Chain 1337's only event sits far above the pre-threshold boundary, with chain
// 100 left just ahead of it so the fetch budget still comes back to 1337. Once
// the block-100 checkpoints are pruned, chain 1337 has nothing at or below the
// block a reorg deeper than that event takes it back to, so the rollback finds
// no checkpoint to target and falls back to the fork block itself.
let driveToDistantChain1337 = async (
  ~t,
  ~indexer: IndexerRunner.t,
  ~source100: MockSource.t,
  ~source1337: MockSource.t,
) => {
  await Utils.delay(0)
  let _ = await Promise.all2((
    Scenario.enterReorgThreshold(~t, ~indexer, ~source=source100),
    Scenario.enterReorgThreshold(~t, ~indexer, ~source=source1337),
  ))

  source100.resolveGetItemsOrThrow(
    [setCounter(~block=101, ~count=100n)],
    ~latestFetchedBlockNumber=101,
  )
  await MockSource.waitItemsQuery(source1337)
  source1337.resolveGetItemsOrThrow(
    [setCounter(~block=150, ~count=1337n)],
    ~latestFetchedBlockNumber=150,
  )
  await indexer.getBatchWritePromise()

  source100.resolveGetItemsOrThrow(
    [setCounter(~block=102, ~count=1002n)],
    ~latestFetchedBlockNumber=151,
  )
  await indexer.getBatchWritePromise()
}

let checkpoint = (~id, ~chain, ~block, ~events): InternalTable.Checkpoints.t => {
  id,
  chainId: chain->ChainId.fromInt,
  blockNumber: block,
  blockHash: Js.Null.Value(MockSource.evmBlockHash(`0x0${block->Int.toString}`)),
  eventsProcessed: events,
}

let counterSet = (~checkpointId, ~chain, ~count): Change.t<counter> => Set({
  checkpointId,
  entityId: "total"->EntityId.unsafeOfString,
  entity: {id: "total", count, chainId: chain},
})

let progress = (~chain100, ~chain1337): array<IndexerRunner.metric> => [
  {value: chain100, labels: Dict.fromArray([("chainId", "100")])},
  {value: chain1337, labels: Dict.fromArray([("chainId", "1337")])},
]

describe("Isolated multichain rollback", () => {
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
          checkpoint(~id=3n, ~chain=100, ~block=101, ~events=1),
          checkpoint(~id=4n, ~chain=1337, ~block=101, ~events=1),
          checkpoint(~id=5n, ~chain=1337, ~block=102, ~events=1),
          checkpoint(~id=6n, ~chain=100, ~block=102, ~events=1),
        ],
        [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 13372n, chainId: 1337}],
        [
          counterSet(~checkpointId=3n, ~chain=100, ~count=100n),
          counterSet(~checkpointId=4n, ~chain=1337, ~count=1337n),
          counterSet(~checkpointId=5n, ~chain=1337, ~count=13372n),
          counterSet(~checkpointId=6n, ~chain=100, ~count=1002n),
        ],
        progress(~chain100="102", ~chain1337="102"),
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
      ).toEqual((progress(~chain100="102", ~chain1337="101"), Some(103)))

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
          checkpoint(~id=3n, ~chain=100, ~block=101, ~events=1),
          checkpoint(~id=4n, ~chain=1337, ~block=101, ~events=1),
          checkpoint(~id=6n, ~chain=100, ~block=102, ~events=1),
          checkpoint(~id=8n, ~chain=1337, ~block=102, ~events=1),
        ],
        [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [
          counterSet(~checkpointId=3n, ~chain=100, ~count=100n),
          counterSet(~checkpointId=4n, ~chain=1337, ~count=1337n),
          counterSet(~checkpointId=6n, ~chain=100, ~count=1002n),
          counterSet(~checkpointId=8n, ~chain=1337, ~count=999n),
        ],
        progress(~chain100="102", ~chain1337="102"),
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
      ).toEqual((progress(~chain100="101", ~chain1337="101"), true))

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
          checkpoint(~id=3n, ~chain=100, ~block=101, ~events=1),
          checkpoint(~id=4n, ~chain=1337, ~block=101, ~events=1),
          checkpoint(~id=8n, ~chain=100, ~block=102, ~events=1),
          checkpoint(~id=9n, ~chain=1337, ~block=102, ~events=1),
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
          checkpoint(~id=3n, ~chain=100, ~block=101, ~events=1),
          checkpoint(~id=4n, ~chain=1337, ~block=101, ~events=1),
          checkpoint(~id=8n, ~chain=1337, ~block=102, ~events=1),
          checkpoint(~id=10n, ~chain=100, ~block=102, ~events=1),
        ],
        [{id: "total", count: 1003n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [
          counterSet(~checkpointId=3n, ~chain=100, ~count=100n),
          counterSet(~checkpointId=4n, ~chain=1337, ~count=1337n),
          counterSet(~checkpointId=8n, ~chain=1337, ~count=999n),
          counterSet(~checkpointId=10n, ~chain=100, ~count=1003n),
        ],
        progress(~chain100="102", ~chain1337="102"),
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
        (await progressByChain(indexer), await eventsByChain(indexer)),
        ~message="Both chains went back past the lower of the two targets, events with them",
      ).toEqual((
        progress(~chain100="101", ~chain1337="100"),
        progress(~chain100="1", ~chain1337="0"),
      ))

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
          checkpoint(~id=3n, ~chain=100, ~block=101, ~events=1),
          checkpoint(~id=8n, ~chain=100, ~block=102, ~events=1),
          checkpoint(~id=9n, ~chain=1337, ~block=101, ~events=1),
          checkpoint(~id=10n, ~chain=1337, ~block=102, ~events=1),
        ],
        [{id: "total", count: 1003n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [
          counterSet(~checkpointId=3n, ~chain=100, ~count=100n),
          counterSet(~checkpointId=8n, ~chain=100, ~count=1003n),
          counterSet(~checkpointId=9n, ~chain=1337, ~count=1337n),
          counterSet(~checkpointId=10n, ~chain=1337, ~count=999n),
        ],
      ))
    },
  )
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
          progress(~chain100="104", ~chain1337="101"),
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
      ).toEqual((progress(~chain100="104", ~chain1337="101"), [102], [105]))
    },
  )
  // The widened rollback recomputes progress from the checkpoints, and a chain
  // the superseded diff already moved can land on exactly the block it is
  // already at. It is still a chain whose stored progress the write has to
  // correct, so the superseded diff's rows have to survive into this one.
  scenario->Scenario.it(
    "Keeps a superseded diff's progress for a chain the new one leaves where it found it",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveBothChainsToBlock102(~t, ~indexer, ~source100, ~source1337, ~item=setCounter)

      // Chain 100 first, so its target (checkpoint 3) is below chain 1337's
      // (checkpoint 4) and the widened rollback lands on chain 100's own —
      // leaving chain 100 at the 101 the first diff already took it to.
      await reorgAtBlock102(~indexer, ~source=source100, ~sibling=source1337)
      await reorgAtBlock102(~indexer, ~source=source1337, ~sibling=source100)

      source1337.resolveGetItemsOrThrow(
        [setCounter(~block=101, ~count=1337n)],
        ~filter=MockSource.coveringBlock(101),
        ~latestFetchedBlockNumber=101,
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
          source100.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
          source1337.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ),
        ~message="Chain 100 resumes at the block the first, superseded rollback took it back to",
      ).toEqual((progress(~chain100="101", ~chain1337="101"), [102], [102]))
    },
  )

  // A rollback never moves a chain forward. When the superseded diff took its
  // chain below every checkpoint that chain has left, the rollback replacing it
  // recomputes that chain's progress from those same checkpoints — a block the
  // chain is no longer at. Only the chain that reorged this time is clamped to
  // its own fork block, so the superseded chain has to be held down by where the
  // first rollback already left it.
  //
  // Run on the cross-chain schema because the first rollback has to take both
  // chains back: an isolated one leaves the sibling ahead, and the reorg chain
  // then holds the fetch budget as the furthest behind, so the sibling never
  // gets to reorg on top of it. The scope reaches the same recompute either way.
  crossChainScenario->Scenario.it(
    "Keeps a superseded chain below the checkpoints the new rollback recomputes from",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)

      await driveToDistantChain1337(~t, ~indexer, ~source100, ~source1337)

      // Chain 1337 forks below block 150, its only checkpoint: nothing of its
      // own is at or under the fork, so the rollback has no checkpoint to target
      // and falls back to the fork block, clamping the block-150 checkpoint's
      // recomputed 149 down to 100.
      await reorgAt(
        ~indexer,
        ~source=source1337,
        ~sibling=source100,
        ~atBlock=150,
        ~scanned=[(100, #valid), (150, #orphaned)],
      )

      t.expect(
        await progressByChain(indexer),
        ~message="Chain 1337 went back to the fork block, below its only checkpoint",
      ).toEqual(progress(~chain100="100", ~chain1337="100"))

      // No batch has carried that diff, so this reorg supersedes it. Chain 1337
      // is no longer the reorg chain, so its progress is recomputed from the
      // block-150 checkpoint still in the database — 49 blocks above where the
      // superseded rollback left it.
      await reorgAt(~indexer, ~source=source100, ~sibling=source1337, ~atBlock=100)

      t.expect(
        (await progressByChain(indexer), await eventsByChain(indexer)),
        ~message="Chain 1337 stays at the fork block the superseded rollback took it to",
      ).toEqual((
        progress(~chain100="100", ~chain1337="100"),
        progress(~chain100="0", ~chain1337="0"),
      ))

      t.expect(
        source1337.getItemsOrThrowCalls
        ->Array.map(call => call.payload["fromBlock"])
        ->Array.toSorted(Int.compare)
        ->Array.get(0),
        ~message="Chain 1337 re-fetches from just above the fork, not from its lost checkpoint",
      ).toEqual(Some(101))
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
          progress(~chain100="102", ~chain1337="102"),
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
          counterSet(~checkpointId=3n, ~chain=100, ~count=100n),
          counterSet(~checkpointId=4n, ~chain=1337, ~count=1337n),
          counterSet(~checkpointId=6n, ~chain=100, ~count=1002n),
          counterSet(~checkpointId=8n, ~chain=1337, ~count=999n),
        ],
        [{id: "total", count: 1002n, chainId: 100}, {id: "total", count: 999n, chainId: 1337}],
        [
          checkpoint(~id=1n, ~chain=100, ~block=100, ~events=0),
          checkpoint(~id=2n, ~chain=1337, ~block=100, ~events=0),
          checkpoint(~id=3n, ~chain=100, ~block=101, ~events=1),
          checkpoint(~id=4n, ~chain=1337, ~block=101, ~events=1),
          checkpoint(~id=6n, ~chain=100, ~block=102, ~events=1),
          checkpoint(~id=8n, ~chain=1337, ~block=102, ~events=1),
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
