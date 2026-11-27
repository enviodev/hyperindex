open Vitest

let addresses = [
  "0x0000000000000000000000000000000000000001",
  "0x0000000000000000000000000000000000000002",
  "0x0000000000000000000000000000000000000003",
  "0x0000000000000000000000000000000000000004",
]

let scenarioWith = (~endBlock="", ~addressCount) =>
  Scenario.make(
    ~configYaml=`
name: fetch-state-next-query-order
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0${endBlock}
    contracts:
      - name: Gravatar
        address:
${addresses
      ->Array.slice(~start=0, ~end=addressCount)
      ->Array.map(address => `          - "${address}"`)
      ->Array.join("\n")}
        events:
          - event: "TestEvent()"
`,
    ~schema=`
type Seen {
  id: ID!
}
`,
  )

type queryShape = {
  fromBlock: int,
  toBlock: MockSource.toBlock,
  reservedItems: option<int>,
  addresses: array<string>,
}

// The items reserved by an open-ended probe. Probes starting at one block are
// told apart by the order they were started in, which is the order they reached
// the source.
let probeReservation = (
  mock: MockSource.t,
  ~indexer: IndexerRunner.t,
  query: MockSource.pendingItemsQuery,
) =>
  switch query.toBlock {
  | Bounded(_) => None
  | Unbounded =>
    let isProbeAtSameBlock = (other: MockSource.pendingItemsQuery) =>
      other.retryCount === 0 && other.fromBlock === query.fromBlock && other.toBlock === Unbounded
    let earlierProbes =
      [...mock.repliedItemsQueries, ...mock.pendingItemsQueries]
      ->Array.filter(other =>
        other->isProbeAtSameBlock && other->MockSource.queryId < query->MockSource.queryId
      )
      ->Array.length
    indexer
    ->QueryReservations.startedTicks
    ->Array.flat
    ->Array.filter(request => request.fromBlock === query.fromBlock && request.targetBlock === None)
    ->Array.get(earlierProbes)
    ->Option.map(request => request.reservedItems)
  }

// The pending queries, each open-ended probe with the buffer items it reserved.
let pendingShapes = (source: MockSource.t, ~indexer: IndexerRunner.t) =>
  source.pendingItemsQueries->Array.map(query => {
    fromBlock: query.fromBlock,
    toBlock: query.toBlock,
    reservedItems: source->probeReservation(~indexer, query),
    addresses: query->MockSource.addresses->Array.map(Address.toString),
  })

let upTo = latestFetchedBlockNumber => MockSource.Respond({items: [], latestFetchedBlockNumber})

let staggeredStarts = Scenario.make(
  ~configYaml=`
name: fetch-state-next-query-staggered
rollback_on_reorg: false
contracts:
  - name: Early
    events:
      - event: "TestEvent()"
  - name: Middle
    events:
      - event: "TestEvent()"
  - name: Late
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0
    contracts:
      - name: Middle
        address: "0x0000000000000000000000000000000000000001"
        start_block: 5
      - name: Late
        address: "0x0000000000000000000000000000000000000002"
        start_block: 6
      - name: Early
        address: "0x0000000000000000000000000000000000000003"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Early", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "Middle", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "Late", event: "TestEvent" }, async () => {});
`,
)

describe("Indexing plan: next query order", () => {
  staggeredStarts->Scenario.it(
    "Queries every group behind the head, furthest behind first",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100_000)
      await sync.expectItemsQueries([
        {reply: LeavePending},
        {reply: LeavePending},
        {reply: LeavePending},
      ])
      // The chain has no density yet, so each probe reserves a 5000-item page
      // whatever its start, and the default pool's cold budget holds all three.
      t.expect(sync->pendingShapes(~indexer)).toEqual([
        {
          fromBlock: 0,
          toBlock: Unbounded,
          reservedItems: Some(5000),
          addresses: ["0x0000000000000000000000000000000000000003"],
        },
        {
          fromBlock: 5,
          toBlock: Unbounded,
          reservedItems: Some(5000),
          addresses: ["0x0000000000000000000000000000000000000001"],
        },
        {
          fromBlock: 6,
          toBlock: Unbounded,
          reservedItems: Some(5000),
          addresses: ["0x0000000000000000000000000000000000000002"],
        },
      ])
    },
  )

  let exited = ref(false)
  scenarioWith(~addressCount=4, ~endBlock="\n    end_block: 11")->Scenario.it(
    "Queries the head in one stream, waits for a block once it reaches it, and stops at the end block",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=1,
    ~onExit=() => exited := true,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(10)
      await sync.expectItemsQueries([{reply: upTo(6)}])
      await sync.expectItemsQueries([{reply: LeavePending}])
      await indexer.advanceTime(1000)
      await sync.expectNewHeightCalls(0)
      let behindHead = sync->pendingShapes(~indexer)

      await sync.expectItemsQueries([{reply: upTo(10)}])
      await sync.expectNewHeightCalls(1)
      let atHead = sync->pendingShapes(~indexer)

      sync.resolveGetHeightOrThrow(20)
      await sync.expectItemsQueries([{reply: LeavePending}])
      let toEndBlock = sync->pendingShapes(~indexer)
      await indexer.waitUntilIdle()
      let exitedBeforeEndBlock = exited.contents
      await sync.expectItemsQueries([{reply: upTo(11)}])
      await indexer.getBatchWritePromise()
      await indexer.advanceTime(100_000)
      await sync.expectNewHeightCalls(0)

      t.expect((
        behindHead,
        atHead,
        toEndBlock,
        sync->pendingShapes(~indexer),
        exitedBeforeEndBlock,
        exited.contents,
      )).toEqual((
        [{fromBlock: 7, toBlock: Bounded(11), reservedItems: None, addresses}],
        [],
        [{fromBlock: 11, toBlock: Bounded(11), reservedItems: None, addresses}],
        [],
        false,
        true,
      ))
    },
  )

  scenarioWith(
    ~addressCount=1,
  )->Scenario.it(
    "Caps a partition at 12 in-flight chunks, refilling a slot as each chunk lands",
    ~sources=[{chain: 1337}],
    ~targetBufferSize=1_000_000,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let itemsIn = (~from, ~count) =>
        Array.fromInitializer(~length=count, i => {MockSource.blockNumber: from + i, logIndex: 0})
      let chunkRanges = () =>
        sync.pendingItemsQueries->Array.map(
          query => (query.fromBlock, query.toBlock, sync->probeReservation(~indexer, query)),
        )
      sync.resolveGetHeightOrThrow(1_000_000)
      await sync.expectItemsQueries([
        {reply: Respond({items: itemsIn(~from=0, ~count=100), latestFetchedBlockNumber: 99})},
      ])
      await sync.expectItemsQueries([
        {
          fromBlock: 100,
          reply: Respond({items: itemsIn(~from=100, ~count=100), latestFetchedBlockNumber: 199}),
        },
      ])
      await sync.expectItemsQueries([{where: query => query.fromBlock >= 200, reply: LeavePending}])
      await indexer.advanceTime(1000)
      let firstWave = chunkRanges()

      await sync.expectItemsQueries([
        {fromBlock: 200, reply: Respond({items: itemsIn(~from=200, ~count=180)})},
        {fromBlock: 380, reply: Respond({items: itemsIn(~from=380, ~count=180)})},
        {where: query => query.fromBlock > 380, reply: LeavePending},
      ])
      await sync.expectItemsQueries([{where: query => query.fromBlock >= 560, reply: LeavePending}])
      await indexer.advanceTime(1000)

      t.expect((firstWave, chunkRanges())).toEqual((
        Array.fromInitializer(
          ~length=12,
          i => (200 + i * 180, MockSource.Bounded(379 + i * 180), None),
        ),
        Array.fromInitializer(
          ~length=10,
          i => (560 + i * 180, MockSource.Bounded(739 + i * 180), None),
        )->Array.concat([(2360, Bounded(2539), None), (2540, Bounded(2863), None)]),
      ))
    },
  )
})
