open Vitest

// Two single-address partitions; holding partition "1"'s first probe in flight
// keeps the chain cold, so every tick hands partition "0" targetBufferSize / 10
// fresh items. Each first probe reserves a 5000-item page, so the pool is at
// least 100_000 for both to go out at once. An end block gives the probes a
// toBlock.
let makeScenario = (~endBlock=?) =>
  Scenario.make(
    ~configYaml=`
name: fetch-state-response-density
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
${endBlock->Option.mapOr("", endBlock =>
        `    end_block: ${endBlock->Int.toString}\n`
      )}    max_reorg_depth: 0
    contracts:
      - name: Token
        address:
          - "0x0000000000000000000000000000000000000001"
          - "0x0000000000000000000000000000000000000002"
`,
  )

let sources: array<Scenario.sourceMock> = [{chain: 1}]

type issuedQuery = {
  partitionId: string,
  fromBlock: int,
  toBlock: MockSource.toBlock,
}

// The queries issued since the last call, in arrival order.
let takeNewQueries = (mock: MockSource.t, ~seen: array<MockSource.pendingItemsQuery>) => {
  mock
  ->MockSource.takeNewPendingItemsQueries(~seen)
  ->Array.map((query): issuedQuery => {
    partitionId: query.partitionId,
    fromBlock: query.fromBlock,
    toBlock: query.toBlock,
  })
}

let newPartitionZeroQueries = (mock, ~seen) =>
  mock->takeNewQueries(~seen)->Array.filter(query => query.partitionId === "0")

let chunk = (~fromBlock, ~toBlock) => {
  fromBlock,
  toBlock: Bounded(toBlock),
}

// Replies to partition "0"'s query at `fromBlock` with `count(query)` items, all
// at the block the response reaches.
let respond = (mock: MockSource.t, ~fromBlock, ~count, ~latestFetchedBlockNumber) =>
  mock.expectItemsQueries([
    {
      fromBlock,
      reply: RespondWith(
        query => {
          items: Array.fromInitializer(~length=count(query), logIndex => {
            MockSource.blockNumber: latestFetchedBlockNumber,
            logIndex,
          }),
          latestFetchedBlockNumber,
        },
      ),
    },
  ])

let startHoldingPartitionOne = async (mock: MockSource.t) => {
  mock.resolveGetHeightOrThrow(100_000)
  await mock.expectItemsQueries([
    {fromBlock: 1, reply: LeavePending},
    {fromBlock: 1, reply: LeavePending},
  ])
}

// Two 10-block probe responses set up 18-block chunks; with 10000 fresh items
// the blended density decides how many of them go out.
let chunksAfterTwoResponses = async (mock: MockSource.t, ~firstCount, ~secondCount) => {
  await mock->startHoldingPartitionOne
  await mock->respond(~fromBlock=1, ~count=firstCount, ~latestFetchedBlockNumber=10)
  await mock->respond(~fromBlock=11, ~count=_ => secondCount, ~latestFetchedBlockNumber=20)
  await mock.expectItemsQueries([
    {fromBlock: 21, reply: LeavePending},
    {reply: LeavePending},
  ])
  mock->newPartitionZeroQueries(~seen=[])
}

describe("FetchState response density and source range capacity over the indexer loop", () => {
  // No query sends a row limit, so a probe stopping at block 390 is the source
  // stopping, however many items it brought: the 90 blocks become capacity and
  // the chunks span ceil(90 * 1.8) = 162 blocks.
  makeScenario(
    ~endBlock=100_000,
  )->Scenario.it(
    "takes the source range capacity from a probe that stops short of its range",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=100_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      await mock->startHoldingPartitionOne
      await mock->respond(~fromBlock=1, ~count=_ => 1000, ~latestFetchedBlockNumber=300)
      await mock->respond(~fromBlock=301, ~count=_ => 10_000, ~latestFetchedBlockNumber=390)
      await mock.expectItemsQueries([
        {fromBlock: 391, reply: LeavePending},
        {fromBlock: 553, reply: LeavePending},
      ])
      t.expect(mock->newPartitionZeroQueries(~seen=[])).toEqual([
        chunk(~fromBlock=391, ~toBlock=552),
        chunk(~fromBlock=553, ~toBlock=714),
      ])
    },
  )

  makeScenario()->Scenario.it(
    "takes the source range capacity from a chunk that stops short of its range",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=100_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      await mock->startHoldingPartitionOne
      await mock->respond(~fromBlock=1, ~count=_ => 1000, ~latestFetchedBlockNumber=10)
      await mock->respond(~fromBlock=11, ~count=_ => 1000, ~latestFetchedBlockNumber=20)
      await mock.expectItemsQueries([
        {fromBlock: 111, toBlock: Bounded(128), reply: LeavePending},
        {reply: LeavePending},
      ])
      let seen = mock.pendingItemsQueries->Array.copy
      await mock->respond(~fromBlock=21, ~count=_ => 500, ~latestFetchedBlockNumber=25)
      await mock.expectItemsQueries([
        {fromBlock: 26, reply: LeavePending},
        {fromBlock: 174, reply: LeavePending},
        {reply: LeavePending},
      ])
      // Chunks send no item cap, so the 5 blocks it reached are the source's
      // capacity: the gap it left is fetched whole and new chunks shrink to
      // ceil(5 * 1.8) = 9 blocks, filling the pipeline back to 12.
      t.expect(mock->newPartitionZeroQueries(~seen)).toEqual(
        Array.concat(
          [chunk(~fromBlock=26, ~toBlock=38)],
          Array.fromInitializer(
            ~length=6,
            index => chunk(~fromBlock=129 + index * 9, ~toBlock=137 + index * 9),
          ),
        ),
      )
    },
  )

  makeScenario()->Scenario.it(
    "keeps a first response with no items as a zero density sample",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=100_000,
    async (~t, ~indexer as _, ~source) => {
      // (0 + 200) / 2 = 100 items/block prices a chunk at 1800 items: six
      // cover 10000.
      t.expect(
        await source(1)->chunksAfterTwoResponses(~firstCount=_ => 0, ~secondCount=2000),
      ).toEqual(
        Array.fromInitializer(
          ~length=6,
          index => chunk(~fromBlock=21 + index * 18, ~toBlock=38 + index * 18),
        ),
      )
    },
  )

  makeScenario()->Scenario.it(
    "seeds density from the first response",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=100_000,
    async (~t, ~indexer as _, ~source) => {
      // 5000 items over the first probe's 10 blocks. (500 + 100) / 2 = 300
      // items/block prices a chunk at 5400 items: two cover 10000.
      t.expect(
        await source(1)->chunksAfterTwoResponses(~firstCount=_ => 5000, ~secondCount=1000),
      ).toEqual([chunk(~fromBlock=21, ~toBlock=38), chunk(~fromBlock=39, ~toBlock=56)])
    },
  )
})
