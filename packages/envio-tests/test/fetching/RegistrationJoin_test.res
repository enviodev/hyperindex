open Vitest

// An address registered for a contract joins that contract's requests at the
// block they have been asked through, and owes one bounded request by address
// for what lies below it. The groups already being fetched keep their shape.

let tokenA = "0xa000000000000000000000000000000000000001"
let tokenB = "0xb000000000000000000000000000000000000001"
let tokenB2 = "0xb000000000000000000000000000000000000002"
let pair1 = "0x1000000000000000000000000000000000000001"
let pair2 = "0x1000000000000000000000000000000000000002"

let registered = (~blockNumber, contractAddress): MockSource.itemMock => {
  event: "Factory.Register",
  blockNumber,
  logIndex: 0,
  params: dict{"contractAddress": contractAddress->(Utils.magic: string => unknown)},
}

let upTo = latestFetchedBlockNumber => MockSource.Respond({items: [], latestFetchedBlockNumber})

let sortedAddresses = (query: MockSource.pendingItemsQuery) =>
  query->MockSource.addresses->Array.map(Address.toString)->Array.toSorted(String.compare)

let chainYaml = (~name, ~contracts) =>
  `
name: ${name}
rollback_on_reorg: false
contracts:
  - name: Factory
    events:
      - event: "Register(address contractAddress)"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:${contracts}
      - name: Factory
`

let handlers = (~registers, ~events) =>
  `
import { indexer } from "envio";

indexer.onEvent({ contract: "Factory", event: "Register", wildcard: true }, async () => {});
indexer.contractRegister(
  { contract: "Factory", event: "Register", wildcard: true },
  async ({ event, context }) => {
    context.chain.${registers}.add(event.params.contractAddress);
  },
);
${events}
`

describe("A group of config addresses of several contracts", () => {
  let scenario = Scenario.make(
    ~configYaml=chainYaml(
      ~name="registration-join-sealed-group",
      ~contracts=`
      - name: TokenA
        address: "${tokenA}"
        events:
          - event: "TestEvent()"
      - name: TokenB
        address: "${tokenB}"
        events:
          - event: "TestEvent()"`,
    ),
    ~handlers=handlers(
      ~registers="TokenB",
      ~events=`indexer.onEvent({ contract: "TokenA", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "TokenB", event: "TestEvent" }, async () => {});`,
    ),
  )

  scenario->Scenario.it(
    "keeps its addresses when one of its contracts registers more",
    ~sources=[{chain: 1337}],
    ~maxAddressesPerGroup=2,
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(1000)
      await sync.expectItemsQueries([
        {address: tokenA, fromBlock: 1, reply: upTo(1000)},
        {
          where: query => query->MockSource.addresses->Array.length == 0,
          fromBlock: 1,
          reply: Respond({
            items: [registered(~blockNumber=50, tokenB2)],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      // The registered address owes its range below the group, by address.
      await sync.expectItemsQueries([
        {
          address: tokenB2,
          fromBlock: 50,
          reply: Respond({items: [], latestFetchedBlockNumber: 1000, knownHeight: 1100}),
        },
        {where: query => query->MockSource.addresses->Array.length == 0, reply: LeavePending},
      ])
      await sync.expectItemsQueries([
        {address: tokenA, reply: LeavePending},
        {address: tokenB2, reply: LeavePending},
        {where: query => query->MockSource.addresses->Array.length == 0, reply: LeavePending},
      ])
      t.expect(
        sync.pendingItemsQueries
        ->Array.map(sortedAddresses)
        ->Array.filter(addresses => addresses->Array.length > 0)
        ->Array.toSorted((a, b) => String.compare(a->Array.join(","), b->Array.join(","))),
      ).toEqual([[tokenA, tokenB], [tokenB2]])
    },
  )
})

describe("An address registered below what its contract has fetched", () => {
  let scenario = Scenario.make(
    ~configYaml=chainYaml(
      ~name="registration-join-catch-up",
      ~contracts=`
      - name: Pair
        address: "${pair1}"
        events:
          - event: "TestEvent()"`,
    ),
    ~handlers=handlers(
      ~registers="Pair",
      ~events=`indexer.onEvent({ contract: "Pair", event: "TestEvent" }, async () => {});`,
    ),
  )

  scenario->Scenario.it(
    "is fetched by address up to the block its contract was asked through, and with it after",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(1000)
      await sync.expectItemsQueries([
        {address: pair1, fromBlock: 1, reply: upTo(300)},
        {where: query => query->MockSource.addresses->Array.length == 0, reply: LeavePending},
      ])
      // Pair's next request is out, open-ended, when the registration lands.
      await sync.expectItemsQueries([
        {address: pair1, fromBlock: 301, reply: LeavePending},
        {
          where: query => query->MockSource.addresses->Array.length == 0,
          fromBlock: 1,
          reply: Respond({
            items: [registered(~blockNumber=10, pair2)],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await sync.expectItemsQueries([
        {address: pair1, fromBlock: 301, reply: upTo(400)},
        {where: query => query->MockSource.addresses->Array.length == 0, reply: LeavePending},
      ])
      await sync.expectItemsQueries([
        {address: pair2, fromBlock: 10, reply: LeavePending},
        {address: pair1, fromBlock: 401, reply: LeavePending},
        {where: query => query->MockSource.addresses->Array.length == 0, reply: LeavePending},
      ])
      t.expect(
        sync.pendingItemsQueries
        ->Array.filter(query => query->MockSource.addresses->Array.length > 0)
        ->Array.map(query => (query.fromBlock, query.toBlock, query->sortedAddresses)),
      ).toEqual([(10, Bounded(400), [pair2]), (401, Unbounded, [pair1, pair2])])
    },
  )
})
