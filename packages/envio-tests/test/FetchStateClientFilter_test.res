open Vitest
open ItemsQueryView.ClientFiltered

// A contract whose registered address count crosses the threshold is fetched
// client-side: its partitions fold into one address-free partition whose
// queries name it in `clientFilteredContracts`. These scenarios stay far from
// the head, so the near-head switch never takes part.
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

// Gravatar and NftFactory's config addresses share partition 0.
let scenario = scenarioOf(~name="fetch-state-client-filter")

let address = n => `0x${n->Int.toString->String.padStart(40, "0")}`->Address.unsafeFromString
let lowercaseGravatarConfigAddress = gravatarConfigAddress->String.toLowerCase

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

// Partition 0 registers two dynamic Gravatar addresses at block 3, so with a
// threshold of 1 Gravatar's three addresses switch it to client-side
// filtering: partition 2 fetches it address-free from block 1, and partition 0
// keeps NftFactory's address from block 6.
let collapseGravatar = async (sourceMock: MockSource.t) => {
  sourceMock.resolveGetHeightOrThrow(1000)
  await sourceMock.expectItemsQueries([
    {
      partitionId: "0",
      fromBlock: 1,
      reply: upTo(~items=[registerAt(3, [address(1), address(2)])], 5),
    },
  ])
}

describe("FetchState client-side address filtering", () => {
  scenario->Scenario.it(
    "fetches a contract over the threshold in one address-free query and keeps the other contract server-side",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {partitionId: "2", reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])

      t.expect(sourceMock->pendingQueries).toEqual([
        {
          partitionId: "2",
          fromBlock: 1,
          toBlock: Unbounded,
          addresses: [],
          clientFilteredContracts: Some(["Gravatar"]),
        },
        {
          partitionId: "0",
          fromBlock: 6,
          toBlock: Unbounded,
          addresses: [nftFactoryConfigAddress],
          clientFilteredContracts: None,
        },
      ])
    },
  )

  scenario->Scenario.it(
    "keeps a contract server-side while its address count is under the threshold",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=10,
    ~maxAddrInPartition=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([
        {partitionId: "0", fromBlock: 1, reply: upTo(~items=[registerAt(3, [address(1)])], 5)},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])

      t.expect(sourceMock->pendingQueries).toEqual([
        {
          partitionId: "2",
          fromBlock: 3,
          toBlock: Unbounded,
          addresses: [address(1)->Address.toString],
          clientFilteredContracts: None,
        },
        {
          partitionId: "0",
          fromBlock: 6,
          toBlock: Unbounded,
          addresses: [nftFactoryConfigAddress, lowercaseGravatarConfigAddress],
          clientFilteredContracts: None,
        },
      ])
    },
  )

  scenarioOf(
    ~name="fetch-state-client-filter-block-handler",
    ~withBlockHandler=true,
  )->Scenario.it(
    "leaves the block handler's partition out of the collapse",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([
        {partitionId: "0", fromBlock: 1, reply: LeavePending},
        {
          partitionId: "1",
          fromBlock: 1,
          reply: upTo(~items=[registerAt(3, [address(1), address(2)])], 5),
        },
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
        {partitionId: "3", reply: LeavePending},
      ])

      t.expect(
        sourceMock.pendingItemsQueries->Array.map(
          query => {
            let selection = query->MockSource.selection
            (
              query.partitionId,
              query.fromBlock,
              selection.onBlockRegistrations->Array.map(registration => registration.name),
              selection.onEventRegistrations->Array.map(
                registration => registration.eventConfig.contractName,
              ),
              selection.clientFilteredContracts,
            )
          },
        ),
        ~message="the block partition keeps its own query, with no contract client-filtered",
      ).toEqual([
        ("0", 1, ["headers"], [], None),
        ("3", 1, [], ["Gravatar"], Some(["Gravatar"])),
        ("1", 6, [], ["NftFactory", "SimpleNft", "Gravatar"], None),
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
    // One address per partition would chunk the six addresses into six
    // partitions, had they been built before the collapse.
    ~maxAddrInPartition=1,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])

      t.expect(
        sourceMock->pendingQueries,
        ~message="one query, from the first partition index",
      ).toEqual([
        {
          partitionId: "0",
          fromBlock: 1,
          toBlock: Unbounded,
          addresses: [],
          clientFilteredContracts: Some(["Gravatar"]),
        },
      ])
    },
  )

  scenarioOf(
    ~name="fetch-state-client-filter-mixed-config",
    ~gravatarAddresses=[1, 2, 3]->Array.map(n => address(n)->Address.toString),
  )->Scenario.it(
    "strips a client-filtered contract's addresses from a partition shared with a server-side contract",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=2,
    ~maxAddrInPartition=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      sourceMock.resolveGetHeightOrThrow(1000)
      await sourceMock.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
      ])

      t.expect(
        sourceMock.pendingItemsQueries->Array.map(
          query => (
            query.partitionId,
            query->MockSource.addresses->Array.map(Address.toString),
            (query->MockSource.selection).onEventRegistrations->Array.map(
              registration => registration.eventConfig.contractName,
            ),
            (query->MockSource.selection).clientFilteredContracts,
          ),
        ),
        ~message="Gravatar's addresses leave the shared partition, and the address-free one fetches Gravatar",
      ).toEqual([
        ("0", [nftFactoryConfigAddress], ["NftFactory", "SimpleNft", "Gravatar"], None),
        ("1", [], ["Gravatar"], Some(["Gravatar"])),
      ])
    },
  )

  scenario->Scenario.it(
    "keeps the address-free partition's id across an unrelated registration",
    ~sources=[{chain: 1337}],
    // Gravatar's three addresses cross it; NftFactory's two don't.
    ~clientFilterAddressThreshold=2,
    ~maxAddrInPartition=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: upTo(50)},
        {partitionId: "0", fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
        {
          partitionId: "0",
          fromBlock: 6,
          reply: upTo(~items=[registerAt(~contract="NftFactory", 8, [address(11)])], 10),
        },
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: upTo(100)},
        {partitionId: "3", fromBlock: 8, reply: LeavePending},
        // Partition 0 now fetches NftFactory's config address in chunks.
        {partitionId: "0", reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([{partitionId: "2", fromBlock: 101, reply: LeavePending}])

      t.expect(
        sourceMock->pendingQueries->Array.filter(query => query.partitionId !== "0"),
        ~message="partition 2 goes on from 101 under its own id; NftFactory's new address is fetched server-side",
      ).toEqual([
        {
          partitionId: "3",
          fromBlock: 8,
          toBlock: Bounded(10),
          addresses: [address(11)->Address.toString],
          clientFilteredContracts: None,
        },
        {
          partitionId: "2",
          fromBlock: 101,
          toBlock: Unbounded,
          addresses: [],
          clientFilteredContracts: Some(["Gravatar"]),
        },
      ])
    },
  )

  scenario->Scenario.it(
    "processes an event once when a switch orphans the address-free query in flight",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->collapseGravatar

      // NftFactory crosses the threshold while partition 2's query is out, so
      // the address-free selection grows under a new partition, 3.
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: LeavePending},
        {
          partitionId: "0",
          fromBlock: 6,
          reply: upTo(~items=[registerAt(~contract="NftFactory", 8, [address(11)])], 10),
        },
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: LeavePending},
        {partitionId: "3", fromBlock: 1, reply: LeavePending},
      ])
      let afterSwitch = sourceMock->pendingQueries

      // The orphaned query lands, but partition 3 hasn't fetched that range
      // under the wider selection yet.
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: upTo(~items=[handled->eventAt(200)], 500)},
        {partitionId: "3", fromBlock: 1, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      let handledAfterOrphan = handled->Array.copy

      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 1, reply: upTo(~items=[handled->eventAt(200)], 500)},
      ])
      await indexer.getBatchWritePromise()

      t.expect(
        (afterSwitch, handledAfterOrphan, handled),
        ~message="nothing is processed below the new generation's frontier, and the re-delivered event is processed once",
      ).toEqual((
        [
          {
            partitionId: "2",
            fromBlock: 1,
            toBlock: Unbounded,
            addresses: [],
            clientFilteredContracts: Some(["Gravatar"]),
          },
          {
            partitionId: "3",
            fromBlock: 1,
            toBlock: Unbounded,
            addresses: [],
            clientFilteredContracts: Some(["Gravatar", "NftFactory"]),
          },
        ],
        [],
        [200],
      ))
    },
  )

  scenario->Scenario.it(
    "accepts every chunk of a retired generation until the last one lands",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->collapseGravatar

      // Two dense responses teach partition 2 to fetch in chunks.
      let dense = from =>
        Array.fromInitializer(
          ~length=10,
          (i): MockSource.itemMock => {blockNumber: from + i, logIndex: 0},
        )
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: upTo(~items=dense(10), 50)},
        {partitionId: "0", fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: upTo(~items=dense(60), 100)},
        {partitionId: "0", fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 911, toBlock: Bounded(1000), reply: LeavePending},
        {partitionId: "2", reply: LeavePending},
        {partitionId: "0", fromBlock: 6, reply: LeavePending},
      ])
      let chunks =
        sourceMock.pendingItemsQueries
        ->Array.filter(query => query.partitionId === "2")
        ->Array.map(query => (query.fromBlock, query.toBlock))

      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 6,
          reply: upTo(~items=[registerAt(~contract="NftFactory", 8, [address(11)])], 10),
        },
      ])
      // The first chunk lands past the block the retired generation stopped
      // at; the others are still owed.
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 101, reply: upTo(190)},
        {partitionId: "3", reply: LeavePending},
        {partitionId: "4", reply: LeavePending},
      ])
      await sourceMock.respondUpTo(1000, ~items=[handled->eventAt(950)])
      await indexer.getBatchWritePromise()

      t.expect(
        (chunks->Array.length, handled, sourceMock->pendingQueries),
        ~message="ten chunks in flight; the last one's event is processed once and nothing else is asked",
      ).toEqual((10, [950], []))
    },
  )

  scenario->Scenario.it(
    "accepts a backfill's response after a later switch collapses again",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: upTo(50)},
        {partitionId: "0", fromBlock: 6, reply: LeavePending},
      ])

      // NftFactory crosses the threshold too. Its partition sits below the
      // address-free frontier, so folding it in leaves backfill partition 4
      // over [6, 50].
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
        {
          partitionId: "0",
          fromBlock: 6,
          reply: upTo(~items=[registerAt(~contract="NftFactory", 8, [address(11)])], 10),
        },
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
        {partitionId: "4", fromBlock: 6, toBlock: Bounded(50), reply: LeavePending},
        {partitionId: "3", fromBlock: 51, reply: LeavePending},
      ])
      let withBackfill = sourceMock->pendingQueries

      // SimpleNft crosses the threshold while the backfill is mid-query.
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
        {partitionId: "4", fromBlock: 6, reply: LeavePending},
        {
          partitionId: "3",
          fromBlock: 51,
          reply: upTo(
            ~items=[registerAt(~contract="SimpleNft", 60, [address(21), address(22)])],
            100,
          ),
        },
      ])
      await sourceMock.respondUpTo(1000, ~items=[handled->eventAt(12), handled->eventAt(70)])
      await indexer.getBatchWritePromise()

      t.expect(
        (withBackfill, handled, sourceMock->pendingQueries),
        ~message="the backfill's response still lands after the recollapse, and every event is processed once",
      ).toEqual((
        [
          {
            partitionId: "2",
            fromBlock: 51,
            toBlock: Unbounded,
            addresses: [],
            clientFilteredContracts: Some(["Gravatar"]),
          },
          {
            partitionId: "4",
            fromBlock: 6,
            toBlock: Bounded(50),
            addresses: [],
            clientFilteredContracts: Some(["Gravatar", "NftFactory"]),
          },
          {
            partitionId: "3",
            fromBlock: 51,
            toBlock: Unbounded,
            addresses: [],
            clientFilteredContracts: Some(["Gravatar", "NftFactory"]),
          },
        ],
        [12, 70],
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "accepts the responses of partitions a collapse absorbs while they are in flight",
    ~sources=[{chain: 1337}],
    // The config address and one dynamic address stay server-side, one per
    // partition; the second dynamic address crosses it.
    ~clientFilterAddressThreshold=2,
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      sourceMock.resolveGetHeightOrThrow(1000)
      // NftFactory's partition 0 registers both addresses, while Gravatar's
      // partitions 1 and 2 have queries out.
      await sourceMock.expectItemsQueries([
        {partitionId: "0", fromBlock: 1, reply: upTo(~items=[registerAt(3, [address(1)])], 5)},
        {partitionId: "1", fromBlock: 1, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "0", fromBlock: 6, reply: upTo(~items=[registerAt(8, [address(2)])], 10)},
        {partitionId: "1", fromBlock: 1, reply: LeavePending},
        {partitionId: "2", fromBlock: 3, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "1", fromBlock: 1, reply: LeavePending},
        {partitionId: "2", fromBlock: 3, reply: LeavePending},
        {partitionId: "3", reply: LeavePending},
        {partitionId: "0", reply: LeavePending},
      ])
      let afterCollapse =
        sourceMock->pendingQueries->Array.filter(query => query.partitionId !== "0")
      await sourceMock.respondUpTo(1000, ~items=[handled->eventAt(2), handled->eventAt(9)])
      await indexer.getBatchWritePromise()

      t.expect(
        (afterCollapse, handled),
        ~message="the absorbed partitions' queries stay owned, so their events are processed once",
      ).toEqual((
        [
          {
            partitionId: "1",
            fromBlock: 1,
            toBlock: Unbounded,
            addresses: [lowercaseGravatarConfigAddress],
            clientFilteredContracts: None,
          },
          {
            partitionId: "2",
            fromBlock: 3,
            toBlock: Unbounded,
            addresses: [address(1)->Address.toString],
            clientFilteredContracts: None,
          },
          {
            partitionId: "3",
            fromBlock: 1,
            toBlock: Unbounded,
            addresses: [],
            clientFilteredContracts: Some(["Gravatar"]),
          },
        ],
        [2, 9],
      ))
    },
  )
})
