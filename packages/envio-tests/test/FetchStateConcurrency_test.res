open Vitest

let addressAt = index => `"0x${(index + 1)->Int.toString(~radix=16)->String.padStart(40, "0")}"`

// One single-address partition per address.
let makeScenario = (~addressCount) =>
  Scenario.make(
    ~configYaml=`
name: fetch-state-concurrency
rollback_on_reorg: false
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
    max_reorg_depth: 0
    contracts:
      - name: Token
        address:
${Array.fromInitializer(~length=addressCount, index =>
        `          - ${addressAt(index)}`
      )->Array.join("\n")}
`,
  )

let sources: array<Scenario.sourceMock> = [{chain: 1}]

type issuedQuery = {
  partitionId: string,
  fromBlock: int,
  toBlock: MockSource.toBlock,
  itemsTarget: option<int>,
}

let toIssuedQuery = (query: MockSource.pendingItemsQuery): issuedQuery => {
  partitionId: query.partitionId,
  fromBlock: query.fromBlock,
  toBlock: query.toBlock,
  itemsTarget: query->MockSource.itemsTarget,
}

// The queries issued since the last call, in arrival order.
let takeNewQueries = (mock: MockSource.t, ~seen: array<MockSource.pendingItemsQuery>) => {
  mock
  ->MockSource.takeNewItemsQueries(~seen)
  ->Array.map(toIssuedQuery)
}

let itemsAt = (~blockNumber, ~count) =>
  Array.fromInitializer(~length=count, logIndex => {MockSource.blockNumber, logIndex})

let probe = (~partitionId, ~fromBlock, ~itemsTarget) => {
  partitionId,
  fromBlock,
  toBlock: Unbounded,
  itemsTarget: Some(itemsTarget),
}

let chunk = (~partitionId, ~fromBlock, ~toBlock) => {
  partitionId,
  fromBlock,
  toBlock: Bounded(toBlock),
  itemsTarget: None,
}

describe("FetchState per-chain concurrency over the indexer loop", () => {
  makeScenario(
    ~addressCount=120,
  )->Scenario.it(
    "keeps at most 100 queries in flight while sizing probes by every partition in range",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      let seen = []
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([{reply: LeavePending}])
      let firstRound = mock->takeNewQueries(~seen)
      await mock.expectItemsQueries(
        Array.fromInitializer(
          ~length=30,
          index => {
            MockSource.partitionId: index->Int.toString,
            reply: Respond({items: [], latestFetchedBlockNumber: 10}),
          },
        ),
      )
      await mock.expectItemsQueries([
        {partitionId: "29", fromBlock: 11, reply: LeavePending},
        {reply: LeavePending},
      ])
      let afterThirtyResponses = mock->takeNewQueries(~seen)
      t.expect({
        "firstRound": firstRound,
        "afterThirtyResponses": afterThirtyResponses,
        "inFlight": mock.pendingItemsQueries->Array.length,
      }).toEqual({
        // 1000 cold items split over all 120 partitions in range, though only
        // 100 of them are admitted.
        "firstRound": Array.fromInitializer(
          ~length=100,
          index => probe(~partitionId=index->Int.toString, ~fromBlock=1, ~itemsTarget=8),
        ),
        // Each response frees one slot, taken by the partition furthest behind:
        // first the 20 never queried, then the ones that answered most recently.
        // 21 partitions are in range each time, so each probe gets 1000 / 21.
        "afterThirtyResponses": Array.concat(
          Array.fromInitializer(
            ~length=20,
            index => probe(~partitionId=(100 + index)->Int.toString, ~fromBlock=1, ~itemsTarget=48),
          ),
          Array.fromInitializer(
            ~length=10,
            index => probe(~partitionId=(20 + index)->Int.toString, ~fromBlock=11, ~itemsTarget=48),
          ),
        ),
        "inFlight": 100,
      })
    },
  )

  // Holding partition "1"'s probe keeps the chain cold, handing it
  // targetBufferSize / 10 = 3000 fresh items per tick.
  makeScenario(
    ~addressCount=2,
  )->Scenario.it(
    "keeps a partition querying past its pipeline while only the head chunk is still being fetched",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=30_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          reply: Respond({
            items: itemsAt(~blockNumber=10, ~count=100),
            latestFetchedBlockNumber: 10,
          }),
        },
        {partitionId: "1", fromBlock: 1, reply: LeavePending},
      ])
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 11,
          reply: Respond({
            items: itemsAt(~blockNumber=15, ~count=100),
            latestFetchedBlockNumber: 20,
          }),
        },
      ])
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 21, reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])
      let seen = []
      let pipeline = mock->takeNewQueries(~seen)->Array.filter(query => query.partitionId === "0")
      await mock.expectItemsQueries(
        Array.fromInitializer(
          ~length=11,
          index => {
            MockSource.partitionId: "0",
            fromBlock: 39 + index * 18,
            reply: Respond({items: []}),
          },
        ),
      )
      await mock.expectItemsQueries([{partitionId: "0", reply: LeavePending}])
      t.expect((pipeline, mock->takeNewQueries(~seen))).toEqual((
        // The budget affords 17 chunks of 180 items; the pipeline stops at 12.
        Array.fromInitializer(
          ~length=12,
          index => chunk(~partitionId="0", ~fromBlock=21 + index * 18, ~toBlock=38 + index * 18),
        ),
        // The 11 that landed wait behind the chunk at 21 without holding its
        // slots, so 11 more go out past them, growing to ceil(18 * 1.8) blocks
        // once the full 18-block responses enter the capacity history.
        Array.concat(
          [chunk(~partitionId="0", ~fromBlock=237, ~toBlock=254)],
          Array.fromInitializer(
            ~length=10,
            index =>
              chunk(~partitionId="0", ~fromBlock=255 + index * 33, ~toBlock=287 + index * 33),
          ),
        ),
      ))
    },
  )

  // Partition "0" jumping from block 0 to 100 overtakes partition "1" at 50.
  // Were the partitions left in their old order, the chain would read 100 as
  // fully fetched and process the event at block 80 before partition "1" has
  // covered that block.
  makeScenario(
    ~addressCount=2,
  )->Scenario.it(
    "re-sorts partitions when a response overtakes another",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 1, reply: LeavePending},
        {partitionId: "1", fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 50})},
      ])
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          reply: Respond({
            items: itemsAt(~blockNumber=80, ~count=1),
            latestFetchedBlockNumber: 100,
          }),
        },
        {partitionId: "1", fromBlock: 51, reply: LeavePending},
      ])
      await mock.expectItemsQueries([{partitionId: "0", fromBlock: 101, reply: LeavePending}])
      await indexer.getBatchWritePromise()
      t.expect(await indexer.metric("envio_progress_block")).toEqual([
        {value: "50", labels: dict{"chainId": "1"}},
      ])
    },
  )
})
