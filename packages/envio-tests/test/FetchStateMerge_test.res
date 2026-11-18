open Vitest

let staticAddress = "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3"
let address1 = "0x1111111111111111111111111111111111111111"
let address2 = "0x2222222222222222222222222222222222222222"
let address3 = "0x3333333333333333333333333333333333333333"

// Each scenario learns a head far past where it fetches: within 200 blocks of
// the head, registered contracts are fetched address-free and never get
// partitions of their own.
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-merge
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    max_reorg_depth: 0
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
  ?srcAddress,
  blockNumber,
  logIndex: 0,
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

describe("FetchState partition merging over the indexer loop", () => {
  scenario->Scenario.it(
    "Merges registrations below an idle partition into it, and gives one that would overflow it a partition of its own",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=3,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {
          partitionId: "0",
          reply: Respond({
            items: [
              registering(~blockNumber=1, [address1]),
              registering(~blockNumber=2, [address2]),
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
      ])
      let afterFirstRegistrations = sync->pendingShapes

      await sync.expectItemsQueries([
        {
          partitionId: "1",
          reply: Respond({
            items: [registering(~blockNumber=2, ~srcAddress=address1, [address3])],
            latestFetchedBlockNumber: 10,
          }),
        },
        {partitionId: "0", reply: LeavePending},
      ])
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "2", reply: LeavePending},
      ])
      await indexer.advanceTime(1000)

      t.expect((afterFirstRegistrations, sync->pendingShapes)).toEqual((
        [
          {
            partitionId: "1",
            fromBlock: 1,
            toBlock: Bounded(10),
            addresses: [address1, address2],
          },
          {
            partitionId: "0",
            fromBlock: 11,
            toBlock: Unbounded,
            addresses: [staticAddress, address1, address2],
          },
        ],
        [
          {
            partitionId: "0",
            fromBlock: 11,
            toBlock: Unbounded,
            addresses: [staticAddress, address1, address2],
          },
          {
            partitionId: "2",
            fromBlock: 2,
            toBlock: Unbounded,
            addresses: [address3],
          },
        ],
      ))
    },
  )

  scenario->Scenario.it(
    "Gives a registration between a bounded partition's range its own partition rather than merging into it",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=2,
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {
          partitionId: "0",
          reply: Respond({
            items: [registering(~blockNumber=100, [address1])],
            latestFetchedBlockNumber: 500,
          }),
        },
      ])
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
      ])
      let afterFirstRegistration = sync->pendingShapes

      await sync.expectItemsQueries([
        {
          partitionId: "1",
          reply: Respond({
            items: [registering(~blockNumber=200, ~srcAddress=address1, [address2])],
            latestFetchedBlockNumber: 400,
          }),
        },
        {partitionId: "0", reply: LeavePending},
      ])
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
        {partitionId: "2", reply: LeavePending},
      ])

      t.expect((afterFirstRegistration, sync->pendingShapes)).toEqual((
        [
          {
            partitionId: "1",
            fromBlock: 100,
            toBlock: Bounded(500),
            addresses: [address1],
          },
          {
            partitionId: "0",
            fromBlock: 501,
            toBlock: Unbounded,
            addresses: [staticAddress, address1],
          },
        ],
        [
          {
            partitionId: "0",
            fromBlock: 501,
            toBlock: Unbounded,
            addresses: [staticAddress, address1],
          },
          {
            partitionId: "2",
            fromBlock: 200,
            toBlock: Unbounded,
            addresses: [address2],
          },
          {
            partitionId: "1",
            fromBlock: 401,
            toBlock: Bounded(500),
            addresses: [address1],
          },
        ],
      ))
    },
  )

  let contractAAddress = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let wildcardScenario = Scenario.make(
    ~configYaml=`
name: fetch-state-merge-wildcard
rollback_on_reorg: false
contracts:
  - name: ContractA
    events:
      - event: "Registered(address[] addresses)"
  - name: Gravatar
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
      - name: ContractA
        address: "${contractAAddress}"
      - name: Gravatar
`,
    ~schema=`
type Seen {
  id: ID!
}
`,
    ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "ContractA", event: "Registered" }, async () => {});
indexer.onEvent({ contract: "ContractA", event: "Registered", wildcard: true }, async () => {});
indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});

indexer.contractRegister({ contract: "ContractA", event: "Registered" }, async ({ event, context }) => {
  for (const address of event.params.addresses) {
    context.chain.Gravatar.add(address);
  }
});
`,
  )

  wildcardScenario->Scenario.it(
    "Keeps the wildcard partition apart while registrations get partitions of their own",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=2,
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
      ])
      let initial = sync->pendingShapes
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {
          partitionId: "1",
          reply: Respond({
            items: [
              {
                event: "ContractA.Registered",
                blockNumber: 2,
                logIndex: 0,
                srcAddress: contractAAddress,
                params: dict{"addresses": [address1]->(Utils.magic: array<string> => unknown)},
              },
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
        {partitionId: "2", reply: LeavePending},
      ])
      t.expect((initial, sync->pendingShapes)).toEqual((
        [
          {partitionId: "0", fromBlock: 0, toBlock: Unbounded, addresses: []},
          {partitionId: "1", fromBlock: 0, toBlock: Unbounded, addresses: [contractAAddress]},
        ],
        [
          {partitionId: "0", fromBlock: 0, toBlock: Unbounded, addresses: []},
          {partitionId: "2", fromBlock: 2, toBlock: Unbounded, addresses: [address1]},
          {partitionId: "1", fromBlock: 11, toBlock: Unbounded, addresses: [contractAAddress]},
        ],
      ))
    },
  )

  wildcardScenario->Scenario.it(
    "Keeps querying a wildcard partition behind the head instead of waiting for a new block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(2)
      await sync.expectItemsQueries([
        {partitionId: "0", reply: Respond({items: [], latestFetchedBlockNumber: 1})},
        {partitionId: "1", reply: Respond({items: [], latestFetchedBlockNumber: 2})},
      ])
      await sync.expectItemsQueries([{partitionId: "0", reply: LeavePending}])
      await indexer.advanceTime(1000)
      await sync.expectNewHeightCalls(0)
      t.expect(sync->pendingShapes).toEqual([
        {partitionId: "0", fromBlock: 2, toBlock: Unbounded, addresses: []},
      ])
    },
  )
})
