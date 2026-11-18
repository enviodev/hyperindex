open Vitest

// Two single-address partitions. Holding partition "1"'s first probe in flight
// keeps the chain's buffer frontier at block 0, so nothing becomes ready and the
// chain stays cold: each tick hands it targetBufferSize / 10 fresh items aimed
// at block 20000 (or the head when it's closer).
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-query-budget
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
          - "0x0000000000000000000000000000000000000001"
          - "0x0000000000000000000000000000000000000002"
`,
)

let makeStaggeredScenario = (~vaultStartBlock) =>
  Scenario.make(
    ~configYaml=`
name: fetch-state-query-budget-staggered
rollback_on_reorg: false
contracts:
  - name: Token
    events:
      - event: Transfer()
  - name: Vault
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
        address: "0x0000000000000000000000000000000000000001"
      - name: Vault
        address: "0x0000000000000000000000000000000000000002"
        start_block: ${vaultStartBlock->Int.toString}
`,
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "Vault", event: "Transfer" }, async () => {});
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
  let fresh = mock.pendingItemsQueries->Array.filter(query => !(seen->Array.includes(query)))
  fresh->Array.forEach(query => seen->Array.push(query)->ignore)
  fresh->Array.map((query): issuedQuery => {
    partitionId: query.partitionId,
    fromBlock: query.fromBlock,
    toBlock: query.toBlock,
    itemsTarget: query->MockSource.itemsTarget,
  })
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

// Two probe responses of 100 items over 10 blocks each give partition "0" a
// density of 10 items/block and a source range capacity of 10 blocks, so it
// chunks in ceil(10 * 1.8) = 18-block chunks priced at 180 items.
let givePartitionZeroDensity = async (mock: MockSource.t) => {
  await mock.expectItemsQueries([
    {
      partitionId: "0",
      fromBlock: 1,
      reply: Respond({items: itemsAt(~blockNumber=10, ~count=100), latestFetchedBlockNumber: 10}),
    },
    {partitionId: "1", fromBlock: 1, reply: LeavePending},
  ])
  await mock.expectItemsQueries([
    {
      partitionId: "0",
      fromBlock: 11,
      reply: Respond({items: itemsAt(~blockNumber=15, ~count=100), latestFetchedBlockNumber: 20}),
    },
  ])
}

describe("FetchState query budget over the indexer loop", () => {
  makeStaggeredScenario(
    ~vaultStartBlock=10001,
  )->Scenario.it(
    "splits the cold budget into parallel probes scaled by how much of the range to the target each covers",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      let seen = []
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 1, reply: LeavePending},
        {partitionId: "1", fromBlock: 10_001, reply: LeavePending},
      ])
      // 1000 items over the 20000 blocks to the target: the frontier probe
      // covers all of it, the one starting at 10001 only half.
      t.expect(mock->takeNewQueries(~seen)).toEqual([
        probe(~partitionId="0", ~fromBlock=1, ~itemsTarget=500),
        probe(~partitionId="1", ~fromBlock=10_001, ~itemsTarget=250),
      ])
    },
  )

  scenario->Scenario.it(
    "spends only the fresh budget beside in-flight reservations, lowest block first, overshooting by one query",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      let seen = []
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 1, reply: LeavePending},
        {partitionId: "1", fromBlock: 1, reply: LeavePending},
      ])
      let coldProbes = mock->takeNewQueries(~seen)
      await mock->givePartitionZeroDensity
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 111, toBlock: Bounded(128), reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])
      let chunksBesideReservation = mock->takeNewQueries(~seen)
      await mock.expectItemsQueries([
        {partitionId: "1", fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 5})},
      ])
      await mock.expectItemsQueries([
        {partitionId: "1", fromBlock: 6, reply: LeavePending},
        {partitionId: "0", fromBlock: 165, reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])
      let probeThenChunks = mock->takeNewQueries(~seen)
      t.expect({
        "coldProbes": coldProbes,
        "chunksBesideReservation": chunksBesideReservation,
        "probeThenChunks": probeThenChunks,
      }).toEqual({
        // Two equal shares of the 1000-item cold budget.
        "coldProbes": [
          probe(~partitionId="0", ~fromBlock=1, ~itemsTarget=500),
          probe(~partitionId="1", ~fromBlock=1, ~itemsTarget=500),
        ],
        // Partition "1"'s 500-item probe stays reserved, so partition "0" gets
        // the 1000 fresh items, not 1500: five 180-item chunks fit and a sixth
        // overshoots. Chunks are bounded by their range, so they send no cap.
        "chunksBesideReservation": [
          chunk(~partitionId="0", ~fromBlock=21, ~toBlock=38),
          chunk(~partitionId="0", ~fromBlock=39, ~toBlock=56),
          chunk(~partitionId="0", ~fromBlock=57, ~toBlock=74),
          chunk(~partitionId="0", ~fromBlock=75, ~toBlock=92),
          chunk(~partitionId="0", ~fromBlock=93, ~toBlock=110),
          chunk(~partitionId="0", ~fromBlock=111, ~toBlock=128),
        ],
        // Partition "1" (no density yet) probes with half the fresh budget and,
        // starting lowest, is funded first; partition "0"'s 1080 in flight are
        // charged next, leaving room for two more chunks and an overshoot.
        "probeThenChunks": [
          probe(~partitionId="1", ~fromBlock=6, ~itemsTarget=500),
          chunk(~partitionId="0", ~fromBlock=129, ~toBlock=146),
          chunk(~partitionId="0", ~fromBlock=147, ~toBlock=164),
          chunk(~partitionId="0", ~fromBlock=165, ~toBlock=182),
        ],
      })
    },
  )

  scenario->Scenario.it(
    "emits one full chunk when the budget is smaller than a chunk",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=500,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      let seen = []
      mock.resolveGetHeightOrThrow(100_000)
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 1, reply: LeavePending},
        {partitionId: "1", fromBlock: 1, reply: LeavePending},
      ])
      let coldProbes = mock->takeNewQueries(~seen)
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          reply: Respond({
            items: itemsAt(~blockNumber=10, ~count=25),
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 11,
          reply: Respond({
            items: itemsAt(~blockNumber=15, ~count=50),
            latestFetchedBlockNumber: 20,
          }),
        },
      ])
      await mock.expectItemsQueries([{partitionId: "0", fromBlock: 21, reply: LeavePending}])
      let chunks = mock->takeNewQueries(~seen)
      t.expect((coldProbes, chunks)).toEqual((
        [
          probe(~partitionId="0", ~fromBlock=1, ~itemsTarget=25),
          probe(~partitionId="1", ~fromBlock=1, ~itemsTarget=25),
        ],
        // Density (2.5 + 5) / 2 prices an 18-block chunk at 68 items, past the
        // 50-item budget, yet the first chunk still goes out whole.
        [chunk(~partitionId="0", ~fromBlock=21, ~toBlock=38)],
      ))
    },
  )

  scenario->Scenario.it(
    "starts no chunk past the target block and trims the last one to it",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      let seen = []
      // The head at 60 is the target: well short of what the budget affords.
      mock.resolveGetHeightOrThrow(60)
      await mock->givePartitionZeroDensity
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 57, reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])
      t.expect(
        mock->takeNewQueries(~seen)->Array.filter(query => query.partitionId === "0"),
      ).toEqual([
        chunk(~partitionId="0", ~fromBlock=21, ~toBlock=38),
        chunk(~partitionId="0", ~fromBlock=39, ~toBlock=56),
        chunk(~partitionId="0", ~fromBlock=57, ~toBlock=60),
      ])
    },
  )

  // Token alone up to Vault's start, more than 20000 blocks later, gets a
  // partition of its own that merges into the shared one at block 30000.
  makeStaggeredScenario(
    ~vaultStartBlock=30_001,
  )->Scenario.it(
    "gates chunk starts at the target block but keeps the last chunk's span up to a far merge block",
    ~sources,
    ~maxAddrInPartition=2,
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(60)
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 1,
          reply: Respond({
            items: itemsAt(~blockNumber=10, ~count=100),
            latestFetchedBlockNumber: 10,
          }),
        },
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
        {partitionId: "0", fromBlock: 57, reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])
      t.expect(mock->takeNewQueries(~seen=[])).toEqual([
        chunk(~partitionId="0", ~fromBlock=21, ~toBlock=38),
        chunk(~partitionId="0", ~fromBlock=39, ~toBlock=56),
        chunk(~partitionId="0", ~fromBlock=57, ~toBlock=74),
      ])
    },
  )

  scenario->Scenario.it(
    "fills the gap behind a returned chunk even when that chunk holds more items than the budget",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      await mock->givePartitionZeroDensity
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 111, reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])
      let seen = mock.pendingItemsQueries->Array.copy
      // The chunk at 39 lands with 12000 items it can't release until the
      // chunk at 21, which stops short at block 30, is filled in.
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 39,
          reply: Respond({
            items: itemsAt(~blockNumber=40, ~count=12_000),
            latestFetchedBlockNumber: 56,
          }),
        },
      ])
      await mock.expectItemsQueries([{partitionId: "0", fromBlock: 129, reply: LeavePending}])
      let afterDenseChunk = mock->takeNewQueries(~seen)
      await mock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 21,
          reply: Respond({items: [], latestFetchedBlockNumber: 30}),
        },
      ])
      await mock.expectItemsQueries([{partitionId: "0", fromBlock: 31, reply: LeavePending}])
      t.expect((afterDenseChunk, mock->takeNewQueries(~seen))).toEqual((
        // The 180 items it released buy one chunk, now priced at the new density.
        [chunk(~partitionId="0", ~fromBlock=129, ~toBlock=146)],
        [chunk(~partitionId="0", ~fromBlock=31, ~toBlock=38)],
      ))
    },
  )

  let respondInOrder = (~denseFirst) =>
    async (
      ~t: Vitest.testContext,
      ~indexer: IndexerRunner.t,
      ~source: (int, ~index: int=?) => MockSource.t,
    ) => {
      let mock = source(1)
      mock.resolveGetHeightOrThrow(100_000)
      let dense: MockSource.expectedItemsQuery = {
        partitionId: "0",
        reply: Respond({items: itemsAt(~blockNumber=10, ~count=100), latestFetchedBlockNumber: 10}),
      }
      let empty: MockSource.expectedItemsQuery = {
        partitionId: "1",
        reply: Respond({items: [], latestFetchedBlockNumber: 10}),
      }
      await mock.expectItemsQueries(denseFirst ? [dense, empty] : [empty, dense])
      await indexer.getBatchWritePromise()
      await mock.expectItemsQueries([
        {partitionId: "0", fromBlock: 11, reply: LeavePending},
        {partitionId: "1", fromBlock: 11, reply: LeavePending},
      ])
      t.expect(mock->takeNewQueries(~seen=[])).toEqual([
        probe(~partitionId="1", ~fromBlock=11, ~itemsTarget=1000),
        probe(~partitionId="0", ~fromBlock=11, ~itemsTarget=8900),
      ])
    }

  scenario->Scenario.it(
    "issues the same next queries when the dense partition's response lands first",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    respondInOrder(~denseFirst=true),
  )

  scenario->Scenario.it(
    "issues the same next queries when the dense partition's response lands last",
    ~sources,
    ~maxAddrInPartition=1,
    ~targetBufferSize=10_000,
    respondInOrder(~denseFirst=false),
  )
})
