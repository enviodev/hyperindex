open Vitest

let staticAddress = "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3"
let address1 = "0x1111111111111111111111111111111111111111"
let address2 = "0x2222222222222222222222222222222222222222"
let address3 = "0x3333333333333333333333333333333333333333"

let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-rollback-partitions
rollback_on_reorg: true
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 199
    contracts:
      - name: Gravatar
        address: "${staticAddress}"
        events:
          - event: "TestEvent(address[] addresses)"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});

indexer.contractRegister({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  for (const address of event.params.addresses) {
    context.chain.Gravatar.add(address);
  }
});
`,
)

let registering = (~blockNumber, ~srcAddress=?, addresses: array<string>): MockSource.itemMock => {
  event: "Gravatar.TestEvent",
  blockNumber,
  logIndex: 0,
  ?srcAddress,
  params: dict{"addresses": addresses->(Utils.magic: array<string> => unknown)},
}

type queryShape = {
  partitionId: string,
  fromBlock: int,
  toBlock: MockSource.toBlock,
  addresses: array<string>,
}

let pendingShapes = (source: MockSource.t) =>
  source.pendingItemsQueries->Array.map(query => {
    partitionId: query.partitionId,
    fromBlock: query.fromBlock,
    toBlock: query.toBlock,
    addresses: query->MockSource.addresses->Array.map(Address.toString),
  })

let upTo = latestFetchedBlockNumber => MockSource.Respond({items: [], latestFetchedBlockNumber})

// Every block below sits past the first query's 9800, inside the reorg
// threshold, where a rollback can reach. Partition "0" holds the static
// address with addresses 1 and 2 registered at blocks 9801 and 9802, fetched to
// block 9810; partition "2" holds address 3, registered at block 9802 and
// fetched to it.
let reachTwoPartitions = async (~indexer: IndexerRunner.t, ~sync: MockSource.t) => {
  sync.resolveGetHeightOrThrow(10_000)
  await sync.expectItemsQueries([{partitionId: "0", toBlock: Bounded(9800), reply: upTo(9800)}])
  await indexer.getBatchWritePromise()
  await sync.expectItemsQueries([
    {
      partitionId: "0",
      reply: Respond({
        items: [
          registering(~blockNumber=9801, [address1]),
          registering(~blockNumber=9802, [address2]),
        ],
        latestFetchedBlockNumber: 9810,
      }),
    },
  ])
  await sync.expectItemsQueries([
    {
      partitionId: "1",
      reply: Respond({
        items: [registering(~blockNumber=9802, ~srcAddress=address1, [address3])],
        latestFetchedBlockNumber: 9810,
      }),
    },
    {partitionId: "0", reply: LeavePending},
  ])
  await sync.expectItemsQueries([
    {partitionId: "2", reply: upTo(9802)},
    {partitionId: "0", reply: LeavePending},
  ])
  await indexer.getBatchWritePromise()
  await sync.expectItemsQueries([
    {
      partitionId: "0",
      reply: Respond({
        items: [],
        latestFetchedBlockNumber: 9820,
        prevRangeLastBlock: {blockNumber: 9810, blockHash: "0x9810a"},
      }),
    },
    {partitionId: "2", reply: LeavePending},
  ])
}

let hashOf = (~blockNumber, ~validUpTo): BlockStore.inputBlock => {
  blockNumber,
  blockHash: blockNumber <= validUpTo
    ? `0x${blockNumber->Int.toString}`
    : `0x${blockNumber->Int.toString}a`,
  blockTimestamp: blockNumber,
}

// Rolls back to `validUpTo` and returns the queries the indexer issues next,
// besides the one partition "2" had in flight from before the reorg.
let queriesAfterRollback = async (~indexer: IndexerRunner.t, ~sync: MockSource.t, ~validUpTo) => {
  await reachTwoPartitions(~indexer, ~sync)
  let inFlightBeforeReorg = sync.pendingItemsQueries->Array.copy
  await sync.expectBlockHashLookup({
    blockNumbers: [9801, 9802],
    reply: [hashOf(~blockNumber=9801, ~validUpTo), hashOf(~blockNumber=9802, ~validUpTo)],
  })
  await indexer.getRollbackReadyPromise()
  await sync.expectItemsQueries([{where: query => query.fromBlock <= 9803, reply: LeavePending}])
  await indexer.advanceTime(10)
  sync
  ->pendingShapes
  ->Array.filterWithIndex((_, index) =>
    !(inFlightBeforeReorg->Array.includes(sync.pendingItemsQueries->Array.getUnsafe(index)))
  )
}

let sources: array<Scenario.sourceMock> = [
  {chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
]

describe("FetchState partitions across a rollback", () => {
  scenario->Scenario.it(
    "Keeps a partition behind the rollback target and refetches the one past it with every surviving address",
    ~sources,
    ~maxAddrInPartition=3,
    async (~t, ~indexer, ~source) => {
      t.expect(await queriesAfterRollback(~indexer, ~sync=source(1337), ~validUpTo=9802)).toEqual([
        {
          partitionId: "1",
          fromBlock: 9803,
          toBlock: Unbounded,
          addresses: [staticAddress, address1, address2],
        },
        {partitionId: "0", fromBlock: 9803, toBlock: Unbounded, addresses: [address3]},
      ])
    },
  )

  scenario->Scenario.it(
    "Drops the addresses registered past the rollback target",
    ~sources,
    ~maxAddrInPartition=3,
    async (~t, ~indexer, ~source) => {
      t.expect(await queriesAfterRollback(~indexer, ~sync=source(1337), ~validUpTo=9801)).toEqual([
        {
          partitionId: "0",
          fromBlock: 9802,
          toBlock: Unbounded,
          addresses: [staticAddress, address1],
        },
      ])
    },
  )

  scenario->Scenario.it(
    "Leaves only the static address once the rollback undoes every registration",
    ~sources,
    ~maxAddrInPartition=3,
    async (~t, ~indexer, ~source) => {
      t.expect(await queriesAfterRollback(~indexer, ~sync=source(1337), ~validUpTo=9800)).toEqual([
        {partitionId: "0", fromBlock: 9801, toBlock: Unbounded, addresses: [staticAddress]},
      ])
    },
  )

  let wildcardScenario = Scenario.make(
    ~configYaml=`
name: fetch-state-rollback-wildcard
rollback_on_reorg: true
contracts:
  - name: Factory
    events:
      - event: "Created(address created)"
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 199
    contracts:
      - name: Factory
      - name: Gravatar
`,
    ~schema=`
type Seen {
  id: ID!
}
`,
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Factory", event: "Created", wildcard: true }, async () => {});
indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});

indexer.contractRegister(
  { contract: "Factory", event: "Created", wildcard: true },
  async ({ event, context }) => {
    context.chain.Gravatar.add(event.params.created);
  },
);
`,
  )

  wildcardScenario->Scenario.it(
    "Keeps the wildcard partition when a rollback undoes the only registration",
    ~sources,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([{partitionId: "0", toBlock: Bounded(9800), reply: upTo(9800)}])
      await indexer.getBatchWritePromise()
      await sync.expectItemsQueries([
        {
          partitionId: "0",
          reply: Respond({
            items: [
              {
                event: "Factory.Created",
                blockNumber: 9802,
                logIndex: 0,
                params: dict{"created": address2->(Utils.magic: string => unknown)},
              },
            ],
            latestFetchedBlockNumber: 9810,
          }),
        },
      ])
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
      ])
      let beforeReorg = sync->pendingShapes
      await indexer.getBatchWritePromise()
      await sync.expectItemsQueries([
        {
          partitionId: "0",
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 9820,
            prevRangeLastBlock: {blockNumber: 9810, blockHash: "0x9810a"},
          }),
        },
        {partitionId: "1", reply: LeavePending},
      ])
      let inFlightBeforeReorg = sync.pendingItemsQueries->Array.copy
      await sync.expectBlockHashLookup({
        blockNumbers: [9802],
        reply: [hashOf(~blockNumber=9802, ~validUpTo=9801)],
      })
      await indexer.getRollbackReadyPromise()
      await sync.expectItemsQueries([
        {where: query => query.fromBlock <= 9802, reply: LeavePending},
      ])
      await indexer.advanceTime(10)
      let afterRollback =
        sync
        ->pendingShapes
        ->Array.filterWithIndex(
          (_, index) =>
            !(
              inFlightBeforeReorg->Array.includes(sync.pendingItemsQueries->Array.getUnsafe(index))
            ),
        )
      t.expect((beforeReorg, afterRollback)).toEqual((
        [
          {partitionId: "1", fromBlock: 9802, toBlock: Unbounded, addresses: [address2]},
          {partitionId: "0", fromBlock: 9811, toBlock: Unbounded, addresses: []},
        ],
        [{partitionId: "0", fromBlock: 9801, toBlock: Unbounded, addresses: []}],
      ))
    },
  )
})
