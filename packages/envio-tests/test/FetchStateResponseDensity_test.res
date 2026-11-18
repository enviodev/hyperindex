open Vitest

// Two single-address partitions; holding partition "1"'s first probe in flight
// keeps the chain cold, so every tick hands partition "0" targetBufferSize / 10
// fresh items. An end block bounds the probes, which then carry both a toBlock
// and an item cap.
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
  itemsTarget: option<int>,
}

// The queries issued since the last call, in arrival order.
let takeNewQueries = (mock: MockSource.t, ~seen: array<MockSource.pendingItemsQuery>) => {
  mock
  ->MockSource.takeNewItemsQueries(~seen)
  ->Array.map((query): issuedQuery => {
    partitionId: query.partitionId,
    fromBlock: query.fromBlock,
    toBlock: query.toBlock,
    itemsTarget: query->MockSource.itemsTarget,
  })
}

let newPartitionZeroQueries = (mock, ~seen) =>
  mock->takeNewQueries(~seen)->Array.filter(query => query.partitionId === "0")

let probe = (~fromBlock, ~toBlock, ~itemsTarget) => {
  partitionId: "0",
  fromBlock,
  toBlock,
  itemsTarget: Some(itemsTarget),
}

let chunk = (~fromBlock, ~toBlock) => {
  partitionId: "0",
  fromBlock,
  toBlock: Bounded(toBlock),
  itemsTarget: None,
}

// Replies to partition "0"'s query at `fromBlock` with `count(query)` items, all
// at the block the response reaches.
let respond = (mock: MockSource.t, ~fromBlock, ~count, ~latestFetchedBlockNumber) =>
  mock.expectItemsQueries([
    {
      partitionId: "0",
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
    {partitionId: "0", fromBlock: 1, reply: LeavePending},
    {partitionId: "1", fromBlock: 1, reply: LeavePending},
  ])
}

let itemsTargetOf = query => query->MockSource.itemsTarget->Option.getOrThrow

// Two 10-block probe responses set up 18-block chunks; with 100 fresh items the
// blended density decides how many of them go out.
let chunksAfterTwoResponses = async (mock: MockSource.t, ~firstCount, ~secondCount) => {
  await mock->startHoldingPartitionOne
  await mock->respond(~fromBlock=1, ~count=_ => firstCount, ~latestFetchedBlockNumber=10)
  await mock->respond(~fromBlock=11, ~count=_ => secondCount, ~latestFetchedBlockNumber=20)
  await mock.expectItemsQueries([
    {partitionId: "0", fromBlock: 21, reply: LeavePending},
    {partitionId: "0", reply: LeavePending},
  ])
  mock->newPartitionZeroQueries(~seen=[])
}

describe("FetchState response density and source range capacity over the indexer loop", () => {
  // The probe at 301 asks for at most 1000 items. Answering all 1000 by block
  // 390 is the cap, not the source, stopping it: the 300-block capacity from the
  // first response stays, so once a second full-range response lands the
  // chunks span 300 * 1.8 = 540 blocks.
  makeScenario(
    ~endBlock=100_000,
  )->Scenario.it(
    "keeps the source range capacity when a capped query stops at its cap",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      let seen = []
      await mock->startHoldingPartitionOne
      await mock->respond(~fromBlock=1, ~count=_ => 100, ~latestFetchedBlockNumber=300)
      await mock.expectItemsQueries([{partitionId: "0", fromBlock: 301, reply: LeavePending}])
      let afterFirst = mock->newPartitionZeroQueries(~seen)
      await mock->respond(~fromBlock=301, ~count=itemsTargetOf, ~latestFetchedBlockNumber=390)
      await mock.expectItemsQueries([{partitionId: "0", fromBlock: 391, reply: LeavePending}])
      let afterCapHit = mock->newPartitionZeroQueries(~seen)
      await mock->respond(~fromBlock=391, ~count=_ => 100, ~latestFetchedBlockNumber=690)
      await mock.expectItemsQueries([{partitionId: "0", fromBlock: 691, reply: LeavePending}])
      t.expect((afterFirst, afterCapHit, mock->newPartitionZeroQueries(~seen))).toEqual((
        [probe(~fromBlock=301, ~toBlock=Bounded(100_000), ~itemsTarget=1000)],
        [probe(~fromBlock=391, ~toBlock=Bounded(100_000), ~itemsTarget=1000)],
        [chunk(~fromBlock=691, ~toBlock=1230)],
      ))
    },
  )

  // 999 of the 1000 items is the source stopping short on its own: the 90
  // blocks become capacity and the chunks span ceil(90 * 1.8) = 162 blocks.
  makeScenario(
    ~endBlock=100_000,
  )->Scenario.it(
    "takes the source range capacity from a capped query that stops short of its cap",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      await mock->startHoldingPartitionOne
      await mock->respond(~fromBlock=1, ~count=_ => 100, ~latestFetchedBlockNumber=300)
      await mock->respond(
        ~fromBlock=301,
        ~count=query => query->itemsTargetOf - 1,
        ~latestFetchedBlockNumber=390,
      )
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 391, reply: LeavePending},
        {partitionId: "0", fromBlock: 553, reply: LeavePending},
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
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      await mock->startHoldingPartitionOne
      await mock->respond(~fromBlock=1, ~count=_ => 100, ~latestFetchedBlockNumber=10)
      await mock->respond(~fromBlock=11, ~count=_ => 100, ~latestFetchedBlockNumber=20)
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 111, toBlock: Bounded(128), reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])
      let seen = mock.pendingItemsQueries->Array.copy
      await mock->respond(~fromBlock=21, ~count=_ => 50, ~latestFetchedBlockNumber=25)
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 26, reply: LeavePending},
        {partitionId: "0", fromBlock: 174, reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
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
    ~targetBufferSize=1_000,
    async (~t, ~indexer as _, ~source) => {
      // (0 + 2) / 2 = 1 item/block prices a chunk at 18 items: six cover 100.
      t.expect(await source(1)->chunksAfterTwoResponses(~firstCount=0, ~secondCount=20)).toEqual(
        Array.fromInitializer(
          ~length=6,
          index => chunk(~fromBlock=21 + index * 18, ~toBlock=38 + index * 18),
        ),
      )
    },
  )

  makeScenario()->Scenario.it(
    "seeds density from a first response that hit its cap",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=1_000,
    async (~t, ~indexer as _, ~source) => {
      // The first probe asks for at most 50 items and gets all 50. (5 + 1) / 2 =
      // 3 items/block prices a chunk at 54 items: two cover 100.
      t.expect(await source(1)->chunksAfterTwoResponses(~firstCount=50, ~secondCount=10)).toEqual([
        chunk(~fromBlock=21, ~toBlock=38),
        chunk(~fromBlock=39, ~toBlock=56),
      ])
    },
  )
})
