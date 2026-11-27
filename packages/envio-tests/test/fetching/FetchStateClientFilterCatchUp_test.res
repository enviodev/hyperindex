open Vitest
open ItemsQueryView.AddressFree

// Once a contract is fetched client-side, an address it registers below what
// the address-free need has requested gets one by-address catch-up over the
// gap, bounded by the block the address-free need was requested through. While
// the address-free query is open-ended and out, that block isn't known, so the
// catch-up waits for it to land.
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-client-filter-catch-up
rollback_on_reorg: false
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
  - name: NftFactory
    events:
      - event: "NftEvent()"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
      - name: NftFactory
        address: "0x00000000000000000000000000000000000000ff"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  // Gravatar's events come from the mock source's own registration.
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "NftFactory", event: "NftEvent" }, async () => {});
`,
)

let nftFactoryConfigAddress = "0x00000000000000000000000000000000000000ff"

let address = n => `0x${n->Int.toString->String.padStart(40, "0")}`->Address.unsafeFromString

type registerOps = {add: Address.t => unit}
type registerContext = {chain: {"Gravatar": registerOps}}

let registerAt = (blockNumber, addresses): MockSource.itemMock => {
  blockNumber,
  logIndex: 0,
  contractRegister: async args => {
    let context = args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)
    addresses->Array.forEach(address => context.chain["Gravatar"].add(address))
  },
}

let eventAt = (handled, blockNumber): MockSource.itemMock => {
  blockNumber,
  logIndex: 1,
  handler: async _ => handled->Array.push(blockNumber)->ignore,
}

let isAddressFree = (query: MockSource.pendingItemsQuery) =>
  (query->MockSource.selection).addressFreeContracts != []

let isConfigGroupQuery = (query: ItemsQueryView.AddressFree.t) =>
  query.addresses->Array.includes(nftFactoryConfigAddress)

let gravatarQueries = (sourceMock: MockSource.t) =>
  sourceMock->pendingQueries->Array.filter(query => !isConfigGroupQuery(query))

let catchUpQueries = (sourceMock: MockSource.t) =>
  sourceMock->gravatarQueries->Array.filter(query => query.addresses != [])

let upTo = (~items=[], block) => MockSource.Respond({items, latestFetchedBlockNumber: block})

let addressFree = (fromBlock, toBlock) => {
  fromBlock,
  toBlock,
  addresses: [],
  addressFreeContracts: ["Gravatar"],
}

let catchUp = (~address=address(3), fromBlock, toBlock) => {
  fromBlock,
  toBlock,
  addresses: [address->Address.toString],
  addressFreeContracts: [],
}

// The config group registers two dynamic Gravatar addresses at block 3,
// crossing the threshold of 1. Its query from 6, out open-ended at a head of
// 1000, still carries Gravatar's config address, so the two are caught up by
// address over [3, 1000]. Both reach 1000 and the chain learns a head of
// `height`: from 1001 Gravatar is fetched address-free.
let reachAddressFree = async (sourceMock: MockSource.t, ~height=2000) => {
  sourceMock.resolveGetHeightOrThrow(1000)
  await sourceMock.expectItemsQueries([
    {
      fromBlock: 1,
      reply: upTo(~items=[registerAt(3, [address(1), address(2)])], 5),
    },
  ])
  await sourceMock.expectItemsQueries([
    {fromBlock: 6, reply: upTo(1000)},
    {fromBlock: 3, toBlock: Bounded(1000), reply: upTo(1000)},
  ])
  sourceMock.resolveGetHeightOrThrow(height)
}

// The address-free need reaches 1050 and has its next, open-ended query out
// when NftFactory's config group fetches to the head and registers address 3
// at `registeredAt`.
let registerWhileAddressFreeQueryIsOpen = async (sourceMock: MockSource.t, ~registeredAt) => {
  await sourceMock->reachAddressFree
  await sourceMock.expectItemsQueries([
    {fromBlock: 1001, where: isAddressFree, reply: upTo(1050)},
    {fromBlock: 1001, address: nftFactoryConfigAddress, reply: LeavePending},
  ])
  await sourceMock.expectItemsQueries([
    {fromBlock: 1051, where: isAddressFree, reply: LeavePending},
    {
      fromBlock: 1001,
      address: nftFactoryConfigAddress,
      reply: upTo(~items=[registerAt(registeredAt, [address(3)])], 2000),
    },
  ])
}

describe("FetchState client-side filtering catch-up requests", () => {
  scenario->Scenario.it(
    "catches an address registered behind the address-free frontier up to it, then drops the catch-up",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->reachAddressFree
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1001,
          where: isAddressFree,
          reply: upTo(~items=[registerAt(1020, [address(3)])], 1050),
        },
        {fromBlock: 1001, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      // The address-free query from 1051 goes out before the contractRegister
      // run registers address 3, so the catch-up waits for it.
      await indexer.waitUntilIdle()
      let whileOpen = sourceMock->gravatarQueries
      await sourceMock.expectItemsQueries([
        {fromBlock: 1051, where: isAddressFree, reply: upTo(1100)},
        {fromBlock: 1001, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1020, reply: LeavePending},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 1001, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      let withCatchUp = sourceMock->catchUpQueries

      await sourceMock.expectItemsQueries([
        {fromBlock: 1020, reply: upTo(~items=[handled->eventAt(1030)], 1100)},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 1001, address: nftFactoryConfigAddress, reply: upTo(2000)},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (whileOpen, withCatchUp, handled, sourceMock->catchUpQueries),
        ~message="the catch-up fetches only the new address up to the address-free frontier, then it is gone",
      ).toEqual(([addressFree(1051, Unbounded)], [catchUp(1020, Bounded(1100))], [1030], []))
    },
  )

  scenario->Scenario.it(
    "gives each successive registration its own catch-up",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=1020)
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {fromBlock: 1051, where: isAddressFree, reply: upTo(1100)},
      ])
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1020,
          toBlock: Bounded(1100),
          reply: upTo(~items=[registerAt(1030, [address(4)])], 1100),
        },
      ])
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {fromBlock: 1101, where: isAddressFree, reply: upTo(1150)},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1030, reply: LeavePending},
        {fromBlock: 1151, where: isAddressFree, reply: LeavePending},
      ])

      t.expect(
        sourceMock->catchUpQueries,
        ~message="address 4 is caught up from its block to what the address-free need has requested",
      ).toEqual([catchUp(~address=address(4), 1030, Bounded(1150))])
    },
  )

  scenario->Scenario.it(
    "holds a catch-up while the address-free query is open-ended, then bounds it at what that query covered",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=1020)
      await indexer.waitUntilIdle()
      let whileOpen = sourceMock->gravatarQueries

      await sourceMock.expectItemsQueries([
        {fromBlock: 1051, where: isAddressFree, reply: upTo(1120)},
      ])
      await sourceMock.expectItemsQueries([{fromBlock: 1020, reply: LeavePending}])

      t.expect(
        (whileOpen, sourceMock->gravatarQueries),
        ~message="no bound is guessed while the address-free query is open-ended; then the catch-up stops at 1120",
      ).toEqual(([addressFree(1051, Unbounded)], [catchUp(1020, Bounded(1120))]))
    },
  )

  scenario->Scenario.it(
    "bounds a catch-up at a reply that comes back past the head its query went out with",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=1020)
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1051,
          where: isAddressFree,
          reply: Respond({items: [], latestFetchedBlockNumber: 2100, knownHeight: 2500}),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1020, reply: LeavePending},
        {fromBlock: 2001, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      t.expect(sourceMock->pendingQueries->Array.filter(query => query.addresses != [])).toEqual([
        catchUp(1020, Bounded(2100)),
        {
          fromBlock: 2001,
          toBlock: Unbounded,
          addresses: [nftFactoryConfigAddress],
          addressFreeContracts: [],
        },
      ])
    },
  )

  scenario->Scenario.it(
    "processes an event both the catch-up and the address-free query fetched once, then drops the catch-up",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=1020)
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1051,
          where: isAddressFree,
          reply: upTo(~items=[handled->eventAt(1060)], 1120),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1020, reply: upTo(~items=[handled->eventAt(1060)], 1120)},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (handled, sourceMock->catchUpQueries),
        ~message="the overlap both requests fetched is processed once, and the catch-up is gone",
      ).toEqual(([1060], []))
    },
  )

  scenario->Scenario.it(
    "keeps a catch-up going to its bound after a partial response",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=1020)
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {fromBlock: 1051, where: isAddressFree, reply: upTo(1200)},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1020, toBlock: Bounded(1200), reply: upTo(1080)},
      ])
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1081,
          toBlock: Bounded(1200),
          reply: upTo(~items=[handled->eventAt(1085)], 1200),
        },
        {fromBlock: 1201, where: isAddressFree, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (handled, sourceMock->catchUpQueries),
        ~message="the catch-up's last response lands, its event is processed once, and the catch-up asks nothing more",
      ).toEqual(([1085], []))
    },
  )

  scenario->Scenario.it(
    "catches an address up over the range the address-free query has in flight above its frontier",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      // Registered at 1060, above the address-free frontier of 1050, but the
      // address-free query from 1051 went out before the address existed.
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=1060)
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {fromBlock: 1051, where: isAddressFree, reply: upTo(1120)},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1121, where: isAddressFree, reply: LeavePending},
        {fromBlock: 1060, reply: LeavePending},
      ])

      t.expect(sourceMock->gravatarQueries).toEqual([
        catchUp(1060, Bounded(1120)),
        addressFree(1121, Unbounded),
      ])
    },
  )

  scenario->Scenario.it(
    "catches up an address registered past where an address-free query already went out",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      // The address-free need fetches to the head it knows, 1300, and waits
      // there.
      await sourceMock->reachAddressFree(~height=1300)
      await sourceMock.expectItemsQueries([
        {fromBlock: 1001, where: isAddressFree, reply: upTo(1300)},
        {fromBlock: 1001, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      // The config group's query comes back past that head, registering
      // address 3 at 1360. The address-free query from 1301 goes out before
      // the contractRegister run registers it, so address 3 gets a catch-up
      // once that query lands.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1001,
          address: nftFactoryConfigAddress,
          reply: Respond({
            items: [registerAt(1360, [address(3)])],
            latestFetchedBlockNumber: 1400,
            knownHeight: 2000,
          }),
        },
      ])
      await indexer.waitUntilIdle()
      let whileOpen = sourceMock->gravatarQueries
      await sourceMock.expectItemsQueries([
        {fromBlock: 1301, where: isAddressFree, reply: upTo(1500)},
        {fromBlock: 1401, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1360, reply: LeavePending},
        {fromBlock: 1501, where: isAddressFree, reply: LeavePending},
        {fromBlock: 1401, address: nftFactoryConfigAddress, reply: LeavePending},
      ])

      t.expect((whileOpen, sourceMock->catchUpQueries)).toEqual((
        [addressFree(1301, Unbounded)],
        [catchUp(1360, Bounded(1500))],
      ))
    },
  )
})
