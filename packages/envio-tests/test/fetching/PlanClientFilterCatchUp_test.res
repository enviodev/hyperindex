open Vitest
open ItemsQueryView.AddressFree

// Once a contract is fetched client-side, an address it registers below what
// the address-free need has requested gets a by-address catch-up over the
// gap, bounded by the block the address-free need was requested through, and
// gone once it gets there. While the address-free query is open-ended and out,
// that block isn't known, so the catch-up goes toward the head and is bounded
// once the query lands.
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
// crossing the threshold of 1: the address-free need reads Gravatar from the
// registration block, 3. The group had covered blocks 1 to 5 already, and its
// query from block 6, out before the registration, still carries Gravatar's
// config address.
let collapseGravatar = async (sourceMock: MockSource.t, ~height=1000) => {
  sourceMock.resolveGetHeightOrThrow(height)
  await sourceMock.expectItemsQueries([
    {
      fromBlock: 1,
      reply: upTo(~items=[registerAt(3, [address(1), address(2)])], 5),
    },
  ])
}

// The address-free need reaches block 50 and has its next, open-ended query
// out when NftFactory's config group fetches to the head and registers
// address 3 at `registeredAt`.
let registerWhileAddressFreeQueryIsOpen = async (sourceMock: MockSource.t, ~registeredAt) => {
  await sourceMock->collapseGravatar
  await sourceMock.expectItemsQueries([
    {fromBlock: 3, where: isAddressFree, reply: upTo(50)},
    {fromBlock: 6, reply: LeavePending},
  ])
  await sourceMock.expectItemsQueries([
    {fromBlock: 51, where: isAddressFree, reply: LeavePending},
    {
      fromBlock: 6,
      reply: upTo(~items=[registerAt(registeredAt, [address(3)])], 1000),
    },
  ])
}

describe("Indexing plan: client-side filtering catch-up requests", () => {
  scenario->Scenario.it(
    "catches an address registered behind the address-free frontier up to it, then drops the catch-up",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 3,
          where: isAddressFree,
          reply: upTo(~items=[registerAt(20, [address(3)])], 50),
        },
        {fromBlock: 6, reply: LeavePending},
      ])
      // The address-free query from 51 goes out before the contractRegister
      // run registers address 3, so the catch-up goes toward the head until
      // that query lands.
      await indexer.waitUntilIdle()
      let whileOpen = sourceMock->pendingQueries
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: upTo(100)},
        {fromBlock: 6, reply: LeavePending},
        {fromBlock: 20, reply: LeavePending},
      ])
      // The address-free need, having learned its density, goes on in chunks.
      await sourceMock.expectItemsQueries([
        {fromBlock: 20, reply: upTo(~items=[handled->eventAt(30)], 60)},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 61, reply: LeavePending},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 6, reply: LeavePending},
      ])
      let withCatchUp = sourceMock->catchUpQueries

      await sourceMock.expectItemsQueries([
        {fromBlock: 61, reply: upTo(100)},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 6, reply: upTo(1000)},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (whileOpen, withCatchUp, handled, sourceMock->catchUpQueries),
        ~message="the catch-up fetches only the new address up to the address-free frontier, then it is gone",
      ).toEqual((
        [
          {
            fromBlock: 6,
            toBlock: Unbounded,
            addresses: [
              "0x00000000000000000000000000000000000000ff",
              "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3",
            ],
            addressFreeContracts: [],
          },
          addressFree(51, Unbounded),
          catchUp(20, Unbounded),
        ],
        [catchUp(61, Bounded(100))],
        [30],
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "gives each successive registration its own catch-up",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 3,
          where: isAddressFree,
          reply: upTo(~items=[registerAt(20, [address(3)])], 50),
        },
        {fromBlock: 6, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: upTo(100)},
        {fromBlock: 6, reply: LeavePending},
        {fromBlock: 20, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 20,
          toBlock: Unbounded,
          reply: upTo(~items=[registerAt(30, [address(4)])], 40),
        },
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 41, reply: LeavePending},
        {fromBlock: 30, reply: LeavePending},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 6, reply: LeavePending},
      ])

      t.expect(
        sourceMock->catchUpQueries,
        ~message="address 4 starts its own catch-up at its block, up to what the address-free need has requested",
      ).toEqual([catchUp(41, Bounded(100)), catchUp(~address=address(4), 30, Bounded(1000))])
    },
  )

  scenario->Scenario.it(
    "catches up toward the head while the address-free query is open-ended, then bounds it at what that query covered",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=20)
      await indexer.waitUntilIdle()
      let whileOpen = sourceMock->gravatarQueries

      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: upTo(120)},
        {fromBlock: 20, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 20, reply: upTo(40)},
        {fromBlock: 121, where: isAddressFree, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 41, reply: LeavePending},
        {fromBlock: 121, where: isAddressFree, reply: LeavePending},
      ])

      t.expect(
        (whileOpen, sourceMock->gravatarQueries),
        ~message="the catch-up goes toward the head while the address-free query is open-ended; then it stops at 120",
      ).toEqual((
        [addressFree(51, Unbounded), catchUp(20, Unbounded)],
        [addressFree(121, Unbounded), catchUp(41, Bounded(120))],
      ))
    },
  )

  scenario->Scenario.it(
    "bounds a catch-up at a reply that comes back past the head its query went out with",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=20)
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 51,
          where: isAddressFree,
          reply: Respond({items: [], latestFetchedBlockNumber: 1100, knownHeight: 1500}),
        },
        {fromBlock: 20, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1101, where: isAddressFree, reply: LeavePending},
        {fromBlock: 20, reply: upTo(40)},
        {fromBlock: 1001, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1101, where: isAddressFree, reply: LeavePending},
        {fromBlock: 41, reply: LeavePending},
        {fromBlock: 1001, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      t.expect(sourceMock->pendingQueries).toEqual([
        {
          fromBlock: 1001,
          toBlock: Unbounded,
          addresses: [nftFactoryConfigAddress],
          addressFreeContracts: [],
        },
        addressFree(1101, Unbounded),
        catchUp(41, Bounded(1100)),
      ])
    },
  )

  scenario->Scenario.it(
    "processes an event both the catch-up and the address-free query fetched once, then drops the catch-up",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=20)
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: upTo(~items=[handled->eventAt(60)], 120)},
        {fromBlock: 20, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 20, reply: upTo(~items=[handled->eventAt(60)], 120)},
        {where: isAddressFree, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (handled, sourceMock->catchUpQueries),
        ~message="the overlap both requests fetched is processed once, and the catch-up is gone",
      ).toEqual(([60], []))
    },
  )

  scenario->Scenario.it(
    "keeps a catch-up going to its bound after a partial response",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=20)
      await indexer.waitUntilIdle()
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: upTo(200)},
        {fromBlock: 20, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 20, toBlock: Unbounded, reply: upTo(80)},
        {fromBlock: 201, where: isAddressFree, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 81,
          toBlock: Bounded(200),
          reply: upTo(~items=[handled->eventAt(85)], 200),
        },
        {fromBlock: 201, where: isAddressFree, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (handled, sourceMock->catchUpQueries),
        ~message="the catch-up's last response lands, its event is processed once, and the catch-up asks nothing more",
      ).toEqual(([85], []))
    },
  )

  scenario->Scenario.it(
    "catches an address up over the range the address-free query has in flight above its frontier",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      // Registered at 60, above the address-free frontier of 50, but the
      // address-free query from 51 went out before the address existed.
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=60)
      await indexer.waitUntilIdle()
      let whileOpen = sourceMock->gravatarQueries
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: upTo(120)},
        {fromBlock: 60, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 121, where: isAddressFree, reply: LeavePending},
        {fromBlock: 60, reply: upTo(80)},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 121, where: isAddressFree, reply: LeavePending},
        {fromBlock: 81, reply: LeavePending},
      ])

      t.expect((whileOpen, sourceMock->gravatarQueries)).toEqual((
        [addressFree(51, Unbounded), catchUp(60, Unbounded)],
        [addressFree(121, Unbounded), catchUp(81, Bounded(120))],
      ))
    },
  )

  scenario->Scenario.it(
    "catches up an address registered past where an address-free query already went out",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      // The address-free need fetches to the head it knows, 1000, and waits
      // there. A head of 1000 rather than main's 50 keeps the needs more than
      // 200 blocks from the head, so they aren't served by one head request.
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {fromBlock: 3, where: isAddressFree, reply: upTo(1000)},
        {fromBlock: 6, reply: LeavePending},
      ])
      // The config group's query comes back past that head, registering
      // address 3 at 1060. The address-free query from 1001 goes out before
      // the contractRegister run registers it, so address 3 catches up toward
      // the head, bounded once that query lands.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 6,
          reply: Respond({
            items: [registerAt(1060, [address(3)])],
            latestFetchedBlockNumber: 1100,
            knownHeight: 2000,
          }),
        },
      ])
      await indexer.waitUntilIdle()
      let whileOpen = sourceMock->gravatarQueries
      await sourceMock.expectItemsQueries([
        {fromBlock: 1001, where: isAddressFree, reply: upTo(1500)},
        {fromBlock: 1101, address: nftFactoryConfigAddress, reply: LeavePending},
        {fromBlock: 1060, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1060, reply: upTo(1200)},
        {fromBlock: 1501, where: isAddressFree, reply: LeavePending},
        {fromBlock: 1101, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1201, reply: LeavePending},
        {fromBlock: 1501, where: isAddressFree, reply: LeavePending},
        {fromBlock: 1101, address: nftFactoryConfigAddress, reply: LeavePending},
      ])

      t.expect((whileOpen, sourceMock->catchUpQueries)).toEqual((
        [addressFree(1001, Unbounded), catchUp(1060, Unbounded)],
        [catchUp(1201, Bounded(1500))],
      ))
    },
  )
})
