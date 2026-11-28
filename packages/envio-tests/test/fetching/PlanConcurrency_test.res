open Vitest

let addressOf = index => `0x${(index + 1)->Int.toString(~radix=16)->String.padStart(40, "0")}`
let addressAt = index => `"${addressOf(index)}"`

// One single-address group per address.
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
  address: string,
  fromBlock: int,
  toBlock: MockSource.toBlock,
  reservedItems: option<int>,
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

// The queries issued since the last call, in arrival order, each probe with
// the buffer items it reserved.
let takeNewQueries = (
  mock: MockSource.t,
  ~indexer: IndexerRunner.t,
  ~seen: array<MockSource.pendingItemsQuery>,
) => {
  mock
  ->MockSource.takeNewPendingItemsQueries(~seen)
  ->Array.map((query): issuedQuery => {
    address: query->MockSource.addresses->Array.map(Address.toString)->Array.join(","),
    fromBlock: query.fromBlock,
    toBlock: query.toBlock,
    reservedItems: mock->probeReservation(~indexer, query),
  })
}

let itemsAt = (~blockNumber, ~count) =>
  Array.fromInitializer(~length=count, logIndex => {MockSource.blockNumber, logIndex})

let probe = (~address, ~fromBlock, ~reservedItems) => {
  address,
  fromBlock,
  toBlock: Unbounded,
  reservedItems: Some(reservedItems),
}

let chunk = (~address, ~fromBlock, ~toBlock) => {
  address,
  fromBlock,
  toBlock: Bounded(toBlock),
  reservedItems: None,
}

describe("Indexing plan: per-chain concurrency over the indexer loop", () => {
  makeScenario(
    ~addressCount=120,
  )->Scenario.it(
    "keeps at most 100 queries in flight while sizing probes by every group in range",
    ~sources,
    ~maxAddressesPerGroup=1,
    ~targetBufferSize=5_000_000,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      let seen = []
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([{reply: LeavePending}])
      let firstRound = mock->takeNewQueries(~indexer, ~seen)
      await mock.expectItemsQueries(
        Array.fromInitializer(
          ~length=30,
          index => {
            MockSource.address: addressOf(index),
            reply: Respond({items: [], latestFetchedBlockNumber: 10}),
          },
        ),
      )
      await mock.expectItemsQueries([
        {fromBlock: 11, address: addressOf(9), reply: LeavePending},
        {reply: LeavePending},
      ])
      let afterThirtyResponses = mock->takeNewQueries(~indexer, ~seen)
      t.expect({
        "firstRound": firstRound,
        "afterThirtyResponses": afterThirtyResponses,
        "inFlight": mock.pendingItemsQueries->Array.length,
      }).toEqual({
        // On a chain with no density each probe reserves a 5000-item page; the
        // 500000-item cold budget holds them all, and the cap admits 100.
        "firstRound": Array.fromInitializer(
          ~length=100,
          index => probe(~address=addressOf(index), ~fromBlock=1, ~reservedItems=5000),
        ),
        // Each response frees one slot, taken by the group furthest behind:
        // first the 20 never queried, still reserving a page each, then the
        // lowest of the ones that answered. Those now have a density, so with
        // 21 groups in range each time each gets 500000 / 21.
        "afterThirtyResponses": Array.concat(
          Array.fromInitializer(
            ~length=20,
            index => probe(~address=addressOf(100 + index), ~fromBlock=1, ~reservedItems=5000),
          ),
          Array.fromInitializer(
            ~length=10,
            index => probe(~address=addressOf(index), ~fromBlock=11, ~reservedItems=23_810),
          ),
        ),
        "inFlight": 100,
      })
    },
  )

  // Holding the second address's probe keeps the chain cold, handing it
  // targetBufferSize / 10 = 30000 fresh items per tick, room for both first
  // probes' 5000-item pages.
  makeScenario(
    ~addressCount=2,
  )->Scenario.it(
    "keeps a group querying past its pipeline while only the head chunk is still being fetched",
    ~sources,
    ~maxAddressesPerGroup=1,
    ~targetBufferSize=300_000,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {
          fromBlock: 1,
          address: addressOf(0),
          reply: Respond({
            items: itemsAt(~blockNumber=10, ~count=1000),
            latestFetchedBlockNumber: 10,
          }),
        },
        {fromBlock: 1, address: addressOf(1), reply: LeavePending},
      ])
      await mock.expectItemsQueries([
        {
          fromBlock: 11,
          reply: Respond({
            items: itemsAt(~blockNumber=15, ~count=1000),
            latestFetchedBlockNumber: 20,
          }),
        },
      ])
      await mock.expectItemsQueries([
        {fromBlock: 21, reply: LeavePending},
        {address: addressOf(0), reply: LeavePending},
      ])
      let seen = []
      let pipeline =
        mock
        ->takeNewQueries(~indexer, ~seen)
        ->Array.filter(query => query.address === addressOf(0))
      await mock.expectItemsQueries(
        Array.fromInitializer(
          ~length=11,
          index => {
            MockSource.fromBlock: 39 + index * 18,
            reply: Respond({items: []}),
          },
        ),
      )
      await mock.expectItemsQueries([{address: addressOf(0), reply: LeavePending}])
      t.expect((pipeline, mock->takeNewQueries(~indexer, ~seen))).toEqual((
        // The budget affords 17 chunks of 1800 items; the pipeline stops at 12.
        Array.fromInitializer(
          ~length=12,
          index =>
            chunk(~address=addressOf(0), ~fromBlock=21 + index * 18, ~toBlock=38 + index * 18),
        ),
        // The 11 that landed wait behind the chunk at 21 without holding its
        // slots, so 11 more go out past them, growing to ceil(18 * 1.8) blocks
        // once the full 18-block responses enter the capacity history.
        Array.concat(
          [chunk(~address=addressOf(0), ~fromBlock=237, ~toBlock=254)],
          Array.fromInitializer(
            ~length=10,
            index =>
              chunk(~address=addressOf(0), ~fromBlock=255 + index * 33, ~toBlock=287 + index * 33),
          ),
        ),
      ))
    },
  )

  // The first address jumping from block 0 to 100 overtakes the second at 50.
  // Were the groups left in their old order, the chain would read 100 as
  // fully fetched and process the event at block 80 before the second has
  // covered that block.
  makeScenario(~addressCount=2)->Scenario.it(
    "re-sorts groups when a response overtakes another",
    ~sources,
    ~maxAddressesPerGroup=1,
    ~targetBufferSize=100_000,
    async (~t, ~indexer, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {fromBlock: 1, address: addressOf(0), reply: LeavePending},
        {
          fromBlock: 1,
          address: addressOf(1),
          reply: Respond({items: [], latestFetchedBlockNumber: 50}),
        },
      ])
      await mock.expectItemsQueries([
        {
          fromBlock: 1,
          address: addressOf(0),
          reply: Respond({
            items: itemsAt(~blockNumber=80, ~count=1),
            latestFetchedBlockNumber: 100,
          }),
        },
        {fromBlock: 51, address: addressOf(1), reply: LeavePending},
      ])
      await mock.expectItemsQueries([{fromBlock: 101, address: addressOf(0), reply: LeavePending}])
      await indexer.getBatchWritePromise()
      t.expect(await indexer.metric("envio_progress_block")).toEqual([
        {value: "50", labels: dict{"chainId": "1"}},
      ])
    },
  )
})
