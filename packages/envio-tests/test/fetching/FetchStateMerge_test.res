open Vitest

let staticAddress = "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3"
let address1 = "0x1111111111111111111111111111111111111111"
let address2 = "0x2222222222222222222222222222222222222222"
let address3 = "0x3333333333333333333333333333333333333333"

// Each scenario learns a head far past where it fetches: within 200 blocks of
// the head, registered contracts are fetched address-free and never get
// groups of their own.
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

let registering = (
  ~blockNumber,
  ~logIndex=0,
  ~srcAddress=?,
  addresses: array<string>,
): MockSource.itemMock => {
  event: "Gravatar.TestEvent",
  ?srcAddress,
  blockNumber,
  logIndex,
  params: dict{"addresses": addresses->(Utils.magic: array<string> => unknown)},
}

let pendingShapes = (source: MockSource.t) =>
  source.pendingItemsQueries->ItemsQueryView.Summary.summarize

let upTo = latestFetchedBlockNumber => MockSource.Respond({items: [], latestFetchedBlockNumber})

describe("FetchState group joins over the indexer loop", () => {
  // The group's open-ended request is out when the registrations land, so
  // they join once it does, at the block it reports.
  scenario->Scenario.it(
    "Joins registrations to the open group, and gives one that would overflow it a group of its own",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=3,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {
          reply: Respond({
            items: [
              registering(~blockNumber=1, [address1]),
              registering(~blockNumber=2, [address2]),
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await indexer.waitUntilIdle()
      await sync.expectItemsQueries([{fromBlock: 11, reply: LeavePending}])
      let afterFirstRegistrations = sync->pendingShapes

      await sync.expectItemsQueries([{fromBlock: 11, reply: upTo(20)}])
      await sync.expectItemsQueries([
        {
          address: address1,
          fromBlock: 1,
          toBlock: Bounded(20),
          reply: Respond({
            items: [registering(~blockNumber=2, ~logIndex=1, ~srcAddress=address1, [address3])],
            latestFetchedBlockNumber: 20,
          }),
        },
        {where: query => query.fromBlock > 20, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      await sync.expectItemsQueries([
        {address: address3, reply: LeavePending},
        {where: query => query.fromBlock > 20, reply: LeavePending},
      ])
      await indexer.advanceTime(1000)

      // The group has a density by now, so it goes on in chunks; the first
      // one shows who is in it.
      t.expect((
        afterFirstRegistrations,
        sync->pendingShapes->Array.slice(~start=0, ~end=2),
      )).toEqual((
        [{fromBlock: 11, toBlock: Unbounded, addresses: [staticAddress]}],
        [
          {fromBlock: 2, toBlock: Unbounded, addresses: [address3]},
          {
            fromBlock: 21,
            toBlock: Bounded(38),
            addresses: [address1, address2, staticAddress],
          },
        ],
      ))
    },
  )

  scenario->Scenario.it(
    "Gives a registration within a catch-up's range a group of its own rather than joining it",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=2,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {
          reply: Respond({
            items: [registering(~blockNumber=100, [address1])],
            latestFetchedBlockNumber: 500,
          }),
        },
      ])
      // The group's next query goes out before the contractRegister run
      // registers address 1, so the address joins the group at the block that
      // query reports and catches up below it.
      await indexer.waitUntilIdle()
      await sync.expectItemsQueries([{fromBlock: 501, reply: upTo(600)}])
      await sync.expectItemsQueries([
        {address: address1, fromBlock: 100, toBlock: Bounded(600), reply: LeavePending},
        {where: query => query.fromBlock > 600, reply: LeavePending},
      ])
      // The group goes on in chunks; its first one shows who is in it.
      let afterFirstRegistration = sync->pendingShapes->Array.slice(~start=0, ~end=2)

      await sync.expectItemsQueries([
        {
          address: address1,
          fromBlock: 100,
          toBlock: Bounded(600),
          reply: Respond({
            items: [registering(~blockNumber=200, ~srcAddress=address1, [address2])],
            latestFetchedBlockNumber: 400,
          }),
        },
        {where: query => query.fromBlock > 600, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      await sync.expectItemsQueries([
        {address: address1, fromBlock: 401, reply: LeavePending},
        {address: address2, reply: LeavePending},
        {where: query => query.fromBlock > 600, reply: LeavePending},
      ])

      t.expect((
        afterFirstRegistration,
        sync->pendingShapes->Array.slice(~start=0, ~end=3),
      )).toEqual((
        [
          {fromBlock: 100, toBlock: Bounded(600), addresses: [address1]},
          {fromBlock: 601, toBlock: Bounded(780), addresses: [address1, staticAddress]},
        ],
        [
          {fromBlock: 200, toBlock: Unbounded, addresses: [address2]},
          {fromBlock: 401, toBlock: Bounded(600), addresses: [address1]},
          {fromBlock: 601, toBlock: Bounded(780), addresses: [address1, staticAddress]},
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

  let isWildcard = (query: MockSource.pendingItemsQuery) => query->MockSource.addresses == []

  wildcardScenario->Scenario.it(
    "Keeps the wildcard request apart while registrations get a group of their own",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=2,
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(10_000)
      await sync.expectItemsQueries([
        {where: isWildcard, reply: LeavePending},
        {address: contractAAddress, reply: LeavePending},
      ])
      let initial = sync->pendingShapes
      await sync.expectItemsQueries([
        {where: isWildcard, reply: LeavePending},
        {
          address: contractAAddress,
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
        {where: isWildcard, reply: LeavePending},
        {address: contractAAddress, reply: LeavePending},
        {address: address1, reply: LeavePending},
      ])
      t.expect((initial, sync->pendingShapes)).toEqual((
        [
          {fromBlock: 0, toBlock: Unbounded, addresses: []},
          {fromBlock: 0, toBlock: Unbounded, addresses: [contractAAddress]},
        ],
        [
          {fromBlock: 0, toBlock: Unbounded, addresses: []},
          {fromBlock: 2, toBlock: Unbounded, addresses: [address1]},
          {fromBlock: 11, toBlock: Unbounded, addresses: [contractAAddress]},
        ],
      ))
    },
  )

  // Within 200 blocks of the head, one request carries the wildcard and the
  // addresses together.
  wildcardScenario->Scenario.it(
    "Keeps querying a wildcard behind the head instead of waiting for a new block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(2)
      await sync.expectItemsQueries([
        {fromBlock: 0, reply: Respond({items: [], latestFetchedBlockNumber: 1})},
      ])
      await sync.expectItemsQueries([{reply: LeavePending}])
      await indexer.advanceTime(1000)
      await sync.expectNewHeightCalls(0)
      t.expect(sync->pendingShapes).toEqual([
        {fromBlock: 2, toBlock: Unbounded, addresses: [contractAAddress]},
      ])
    },
  )
})
