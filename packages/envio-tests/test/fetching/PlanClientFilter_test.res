open Vitest
open ItemsQueryView.AddressFree

// A contract whose registered address count crosses the threshold is fetched
// client-side: its address groups end at the block they were requested
// through, and one address-free need, whose queries name it in
// `addressFreeContracts`, reads it from the earliest start of the addresses
// that crossed it. These scenarios stay far from the head, so the near-head
// switch never takes part.
let gravatarConfigAddress = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
let nftFactoryConfigAddress = "0x00000000000000000000000000000000000000ff"

let addressList = addresses =>
  switch addresses {
  | [] => ""
  | addresses =>
    "\n        address:" ++
    addresses->Array.map(address => `\n          - "${address}"`)->Array.join("")
  }

let scenarioOf = (
  ~name,
  ~gravatarAddresses=[gravatarConfigAddress],
  ~nftFactoryAddresses=[nftFactoryConfigAddress],
  ~withBlockHandler=false,
) =>
  Scenario.make(
    ~configYaml=`
name: ${name}
rollback_on_reorg: false
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
  - name: NftFactory
    events:
      - event: "NftEvent()"
  - name: SimpleNft
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
      - name: Gravatar${gravatarAddresses->addressList}
      - name: NftFactory${nftFactoryAddresses->addressList}
      - name: SimpleNft
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
indexer.onEvent({ contract: "SimpleNft", event: "NftEvent" }, async () => {});
` ++ (
      withBlockHandler
        ? `indexer.onBlock({ name: "headers", fields: { block: ["timestamp"] } }, async () => {});\n`
        : ""
    ),
  )

// Gravatar and NftFactory's config addresses share one group.
let scenario = scenarioOf(~name="fetch-state-client-filter")

let address = n => `0x${n->Int.toString->String.padStart(40, "0")}`->Address.unsafeFromString
let lowercaseGravatarConfigAddress = gravatarConfigAddress->String.toLowerCase

let isConfigGroupQuery = (query: ItemsQueryView.AddressFree.t) =>
  query.addresses->Array.includes(nftFactoryConfigAddress)
let isConfigAddressQuery = (query: ItemsQueryView.AddressFree.t) =>
  query->isConfigGroupQuery || query.addresses->Array.includes(lowercaseGravatarConfigAddress)
let isAddressFree = (query: MockSource.pendingItemsQuery) =>
  (query->MockSource.selection).addressFreeContracts != []

type registerOps = {add: Address.t => unit}
type registerContext = {
  chain: {"Gravatar": registerOps, "NftFactory": registerOps, "SimpleNft": registerOps},
}

let register = (~contract="Gravatar", addresses): MockSource.mockSourceContractRegister =>
  async args => {
    let chain = (
      args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)
    ).chain
    let ops = switch contract {
    | "Gravatar" => chain["Gravatar"]
    | "NftFactory" => chain["NftFactory"]
    | _ => chain["SimpleNft"]
    }
    addresses->Array.forEach(address => ops.add(address))
  }

let registerAt = (~contract=?, blockNumber, addresses): MockSource.itemMock => {
  blockNumber,
  logIndex: 0,
  contractRegister: register(~contract?, addresses),
}

let eventAt = (handled, blockNumber): MockSource.itemMock => {
  blockNumber,
  logIndex: 1,
  handler: async _ => handled->Array.push(blockNumber)->ignore,
}

let upTo = (~items=[], block) => MockSource.Respond({items, latestFetchedBlockNumber: block})

// The config group registers two dynamic Gravatar addresses at block 3, so
// with a threshold of 1 Gravatar's three addresses switch it to client-side
// filtering: the address-free need reads it from the registration block, 3.
// The group had covered blocks 1 to 5 already, and its query from block 6,
// out before the registration, still carries Gravatar's config address.
let collapseGravatar = async (sourceMock: MockSource.t) => {
  sourceMock.resolveGetHeightOrThrow(1000)
  await sourceMock.expectItemsQueries([
    {
      fromBlock: 1,
      reply: upTo(~items=[registerAt(3, [address(1), address(2)])], 5),
    },
  ])
}

let addressFreeQuery = (~contracts=["Gravatar"], fromBlock, toBlock) => {
  fromBlock,
  toBlock,
  addresses: [],
  addressFreeContracts: contracts,
}

describe("Indexing plan: client-side address filtering", () => {
  scenario->Scenario.it(
    "fetches a contract over the threshold in one address-free query and keeps the other contract server-side",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {fromBlock: 6, reply: LeavePending},
        {fromBlock: 3, reply: LeavePending},
      ])

      t.expect(sourceMock->pendingQueries).toEqual([
        {
          fromBlock: 6,
          toBlock: Unbounded,
          addresses: [nftFactoryConfigAddress, lowercaseGravatarConfigAddress],
          addressFreeContracts: [],
        },
        addressFreeQuery(3, Unbounded),
      ])
    },
  )

  scenario->Scenario.it(
    "keeps a contract server-side while its address count is under the threshold",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=10,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([
        {fromBlock: 1, reply: upTo(~items=[registerAt(3, [address(1)])], 5)},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 6, reply: LeavePending},
        {fromBlock: 3, reply: LeavePending},
      ])

      t.expect(sourceMock->pendingQueries).toEqual([
        {
          fromBlock: 6,
          toBlock: Unbounded,
          addresses: [nftFactoryConfigAddress, lowercaseGravatarConfigAddress],
          addressFreeContracts: [],
        },
        {
          fromBlock: 3,
          toBlock: Unbounded,
          addresses: [address(1)->Address.toString],
          addressFreeContracts: [],
        },
      ])
    },
  )

  scenarioOf(
    ~name="fetch-state-client-filter-block-handler",
    ~withBlockHandler=true,
  )->Scenario.it(
    "leaves the block handler's request out of the switch",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([
        {fromBlock: 1, where: query => query->MockSource.addresses == [], reply: LeavePending},
        {
          fromBlock: 1,
          address: nftFactoryConfigAddress,
          reply: upTo(~items=[registerAt(3, [address(1), address(2)])], 5),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1, reply: LeavePending},
        {fromBlock: 6, reply: LeavePending},
        {fromBlock: 3, reply: LeavePending},
      ])

      t.expect(
        sourceMock.pendingItemsQueries->Array.map(
          query => {
            let selection = query->MockSource.selection
            (
              query.fromBlock,
              selection.onBlockRegistrationIndexes->Array.length,
              query->MockSource.addresses->Array.map(Address.toString),
              selection.addressFreeContracts,
            )
          },
        ),
        ~message="the block handler keeps its own query, with no contract client-filtered",
      ).toEqual([
        (1, 1, [], []),
        (6, 0, [nftFactoryConfigAddress, lowercaseGravatarConfigAddress], []),
        (3, 0, [], ["Gravatar"]),
      ])
    },
  )

  scenarioOf(
    ~name="fetch-state-client-filter-config-over-threshold",
    ~gravatarAddresses=[1, 2, 3, 4, 5, 6]->Array.map(n => address(n)->Address.toString),
    ~nftFactoryAddresses=[],
  )->Scenario.it(
    "fetches a config contract over the threshold address-free from the start",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=2,
    // One address per group would chunk the six addresses into six groups,
    // had they been laid out before the switch.
    ~maxAddressesPerGroup=1,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])

      t.expect(sourceMock->pendingQueries, ~message="one address-free query").toEqual([
        addressFreeQuery(1, Unbounded),
      ])
    },
  )

  scenarioOf(
    ~name="fetch-state-client-filter-mixed-config",
    ~gravatarAddresses=[1, 2, 3]->Array.map(n => address(n)->Address.toString),
  )->Scenario.it(
    "strips a client-filtered contract's addresses from a group shared with a server-side contract",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=2,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([
        {fromBlock: 1, where: isAddressFree, reply: LeavePending},
        {fromBlock: 1, address: nftFactoryConfigAddress, reply: LeavePending},
      ])

      t.expect(
        sourceMock->pendingQueries,
        ~message="Gravatar's addresses leave the shared group, and the address-free query fetches Gravatar",
      ).toEqual([
        addressFreeQuery(1, Unbounded),
        {
          fromBlock: 1,
          toBlock: Unbounded,
          addresses: [nftFactoryConfigAddress],
          addressFreeContracts: [],
        },
      ])
    },
  )

  scenario->Scenario.it(
    "keeps the address-free query going across an unrelated registration",
    ~sources=[{chain: 1337}],
    // Gravatar's three addresses cross it; NftFactory's two don't.
    ~clientFilterAddressThreshold=2,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {fromBlock: 3, where: isAddressFree, reply: upTo(50)},
        {fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: LeavePending},
        {
          fromBlock: 6,
          reply: upTo(~items=[registerAt(~contract="NftFactory", 8, [address(11)])], 10),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: upTo(100)},
        {fromBlock: 8, address: address(11)->Address.toString, reply: LeavePending},
        {address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 101, where: isAddressFree, reply: LeavePending},
        {reply: LeavePending},
      ])

      t.expect(
        sourceMock->pendingQueries->Array.filter(query => !isConfigAddressQuery(query)),
        ~message="the address-free query goes on from 101; NftFactory's new address is fetched server-side",
      ).toEqual([
        {
          fromBlock: 8,
          toBlock: Unbounded,
          addresses: [address(11)->Address.toString],
          addressFreeContracts: [],
        },
        addressFreeQuery(101, Unbounded),
      ])
    },
  )

  scenario->Scenario.it(
    "processes an event once when a switch widens the address-free selection with a query in flight",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->collapseGravatar

      // NftFactory crosses the threshold while Gravatar's address-free query
      // is out, and is read address-free from its registration block, 8.
      await sourceMock.expectItemsQueries([
        {fromBlock: 3, where: isAddressFree, reply: LeavePending},
        {
          fromBlock: 6,
          reply: upTo(~items=[registerAt(~contract="NftFactory", 8, [address(11)])], 10),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 3, where: isAddressFree, reply: LeavePending},
        {fromBlock: 8, where: isAddressFree, reply: LeavePending},
        {address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      let afterSwitch = sourceMock->pendingQueries->Array.filter(query => query.addresses == [])

      // The first query lands, but NftFactory hasn't been read over that
      // range yet.
      await sourceMock.expectItemsQueries([
        {fromBlock: 3, where: isAddressFree, reply: upTo(~items=[handled->eventAt(200)], 500)},
        {fromBlock: 8, where: isAddressFree, reply: LeavePending},
        {address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      let handledAfterFirst = handled->Array.copy

      await sourceMock.respondUpTo(1000)
      await indexer.getBatchWritePromise()

      t.expect(
        (afterSwitch, handledAfterFirst, handled),
        ~message="nothing is processed below NftFactory's address-free frontier, and the event is processed once",
      ).toEqual((
        [addressFreeQuery(3, Unbounded), addressFreeQuery(~contracts=["NftFactory"], 8, Unbounded)],
        [],
        [200],
      ))
    },
  )

  scenario->Scenario.it(
    "accepts every chunk of a retired address-free selection until the last one lands",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->collapseGravatar

      // Two dense responses teach the address-free need to fetch in chunks.
      let dense = from =>
        Array.fromInitializer(
          ~length=10,
          (i): MockSource.itemMock => {blockNumber: from + i, logIndex: 0},
        )
      await sourceMock.expectItemsQueries([
        {fromBlock: 3, where: isAddressFree, reply: upTo(~items=dense(10), 50)},
        {fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: upTo(~items=dense(60), 100)},
        {fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 971, toBlock: Bounded(1000), reply: LeavePending},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 6, reply: LeavePending},
      ])
      let chunks =
        sourceMock.pendingItemsQueries
        ->Array.filter(isAddressFree)
        ->Array.map(query => (query.fromBlock, query.toBlock))

      await sourceMock.expectItemsQueries([
        {
          fromBlock: 6,
          reply: upTo(~items=[registerAt(~contract="NftFactory", 8, [address(11)])], 10),
        },
      ])
      await sourceMock.respondUpTo(1000, ~items=[handled->eventAt(950)])
      await indexer.getBatchWritePromise()

      t.expect(
        (chunks->Array.length, handled, sourceMock->pendingQueries),
        ~message="eleven chunks in flight; the last one's event is processed once and nothing else is asked",
      ).toEqual((11, [950], []))
    },
  )

  scenario->Scenario.it(
    "accepts a backfill's response after a later switch widens the selection again",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddressesPerGroup=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {fromBlock: 3, where: isAddressFree, reply: upTo(50)},
        {fromBlock: 6, reply: LeavePending},
      ])

      // NftFactory crosses the threshold too, at block 8, below Gravatar's
      // address-free frontier, so it is read address-free from 8.
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: LeavePending},
        {
          fromBlock: 6,
          reply: upTo(~items=[registerAt(~contract="NftFactory", 8, [address(11)])], 10),
        },
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 51, where: isAddressFree, reply: LeavePending},
        {fromBlock: 8, where: isAddressFree, reply: LeavePending},
        {address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      let withBackfill = sourceMock->pendingQueries->Array.filter(query => query.addresses == [])

      // SimpleNft crosses the threshold while NftFactory's backfill is
      // mid-query.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 51,
          where: isAddressFree,
          reply: upTo(
            ~items=[registerAt(~contract="SimpleNft", 60, [address(21), address(22)])],
            100,
          ),
        },
        {fromBlock: 8, where: isAddressFree, reply: LeavePending},
        {address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      await sourceMock.respondUpTo(1000, ~items=[handled->eventAt(12), handled->eventAt(70)])
      await indexer.getBatchWritePromise()

      t.expect(
        (withBackfill, handled, sourceMock->pendingQueries),
        ~message="the backfill's response still lands after the second switch, and every event is processed once",
      ).toEqual((
        [
          addressFreeQuery(51, Unbounded),
          addressFreeQuery(~contracts=["NftFactory"], 8, Unbounded),
        ],
        [12, 70],
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "accepts the responses of groups a switch ends while they are in flight",
    ~sources=[{chain: 1337}],
    // The config address and one dynamic address stay server-side, one per
    // group; the second dynamic address crosses it.
    ~clientFilterAddressThreshold=2,
    ~maxAddressesPerGroup=1,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      sourceMock.resolveGetHeightOrThrow(1000)
      // NftFactory's group registers both addresses, while Gravatar's groups
      // have queries out.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          address: nftFactoryConfigAddress,
          reply: upTo(~items=[registerAt(3, [address(1)])], 5),
        },
        {fromBlock: 1, address: gravatarConfigAddress, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 6,
          address: nftFactoryConfigAddress,
          reply: upTo(~items=[registerAt(8, [address(2)])], 10),
        },
        {fromBlock: 1, address: gravatarConfigAddress, reply: LeavePending},
        {fromBlock: 3, address: address(1)->Address.toString, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 1, address: gravatarConfigAddress, reply: LeavePending},
        {fromBlock: 3, address: address(1)->Address.toString, reply: LeavePending},
        {where: isAddressFree, reply: LeavePending},
        {address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      let afterSwitch =
        sourceMock->pendingQueries->Array.filter(query => !isConfigGroupQuery(query))
      await sourceMock.respondUpTo(1000, ~items=[handled->eventAt(2), handled->eventAt(9)])
      await indexer.getBatchWritePromise()

      t.expect(
        (afterSwitch, handled),
        ~message="the ended groups' queries still land, so their events are processed once",
      ).toEqual((
        [
          {
            fromBlock: 1,
            toBlock: Unbounded,
            addresses: [lowercaseGravatarConfigAddress],
            addressFreeContracts: [],
          },
          {
            fromBlock: 3,
            toBlock: Unbounded,
            addresses: [address(1)->Address.toString],
            addressFreeContracts: [],
          },
          // From address 2's registration block: the ended groups' in-flight
          // queries still cover the older addresses.
          addressFreeQuery(8, Unbounded),
        ],
        [2, 9],
      ))
    },
  )
})
