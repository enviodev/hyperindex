open Vitest
open ItemsQueryView.ClientFiltered

// Once a contract is fetched client-side, an address it registers below what
// the address-free partition has already covered gets an address-bound
// catch-up partition over the gap, bounded by the block the address-free
// partition is known to have fetched, and gone once it gets there.
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

// The lowest pending query of each partition: a partition that learned its
// event density from a response fetches ahead in chunks.
let nextQueries = (sourceMock: MockSource.t) => {
  let queries = sourceMock->pendingQueries
  queries->Array.filter(query =>
    !(
      queries->Array.some(other =>
        other.partitionId === query.partitionId && other.fromBlock < query.fromBlock
      )
    )
  )
}

let upTo = (~items=[], block) => MockSource.Respond({items, latestFetchedBlockNumber: block})

let addressFree = (~partitionId="2", fromBlock, toBlock) => {
  partitionId,
  fromBlock,
  toBlock,
  addresses: [],
  clientFilteredContracts: Some(["Gravatar"]),
}

let catchUp = (~partitionId="3", ~address=address(3), fromBlock, toBlock) => {
  partitionId,
  fromBlock,
  toBlock,
  addresses: [address->Address.toString],
  clientFilteredContracts: None,
}

// Partition 0 registers two dynamic Gravatar addresses at block 3, crossing
// the threshold of 1: address-free partition 2 fetches Gravatar from block 1,
// while partition 0 keeps NftFactory's address from block 6.
let collapseGravatar = async (sourceMock: MockSource.t, ~height=1000) => {
  sourceMock.resolveGetHeightOrThrow(height)
  await sourceMock.expectItemsQueries([
    {
      partitionId: "0",
      fromBlock: 1,
      reply: upTo(~items=[registerAt(3, [address(1), address(2)])], 5),
    },
  ])
}

// Partition 2 reaches block 50 and has its next, open-ended query out when
// NftFactory's partition 0 fetches to the head and registers address 3 at
// `registeredAt`.
let registerWhileAddressFreeQueryIsOpen = async (sourceMock: MockSource.t, ~registeredAt) => {
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
      reply: upTo(~items=[registerAt(registeredAt, [address(3)])], 1000),
    },
  ])
}

describe("FetchState client-side filtering catch-up partitions", () => {
  scenario->Scenario.it(
    "catches an address registered behind the address-free frontier up to it, then drops the catch-up",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: upTo(~items=[registerAt(20, [address(3)])], 50)},
        {partitionId: "0", fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "3", reply: LeavePending},
        {partitionId: "2", reply: LeavePending},
      ])
      let withCatchUp = sourceMock->pendingQueries

      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 20, reply: upTo(~items=[handled->eventAt(30)], 50)},
        {partitionId: "0", fromBlock: 6, reply: upTo(1000)},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (withCatchUp, handled, sourceMock->pendingQueries),
        ~message="the catch-up fetches only the new address up to block 50, and once there only partition 2 is left",
      ).toEqual((
        [
          {
            partitionId: "0",
            fromBlock: 6,
            toBlock: Unbounded,
            addresses: ["0x00000000000000000000000000000000000000ff"],
            clientFilteredContracts: None,
          },
          catchUp(20, Bounded(50)),
          addressFree(51, Unbounded),
        ],
        [30],
        [addressFree(51, Unbounded)],
      ))
    },
  )

  scenario->Scenario.it(
    "gives each successive registration its own catch-up partition",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->collapseGravatar
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: upTo(~items=[registerAt(20, [address(3)])], 50)},
        {partitionId: "0", fromBlock: 6, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {
          partitionId: "3",
          fromBlock: 20,
          reply: upTo(~items=[registerAt(30, [address(4)])], 40),
        },
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 41, reply: LeavePending},
        {partitionId: "4", reply: LeavePending},
      ])

      t.expect(
        sourceMock->pendingQueries->Array.filter(query => query.partitionId !== "0"),
        ~message="address 4 starts its own catch-up at its block; partition 2 keeps its id",
      ).toEqual([
        addressFree(51, Unbounded),
        catchUp(~partitionId="4", ~address=address(4), 30, Unbounded),
        catchUp(41, Bounded(50)),
      ])
    },
  )

  scenario->Scenario.it(
    "leaves a catch-up unbounded while the address-free query is open-ended, then bounds it at what that query covered",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=20)
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
        {partitionId: "3", fromBlock: 20, reply: LeavePending},
      ])
      let whileOpen = sourceMock->pendingQueries

      // Partition 2's query comes back at 120, past the head it went out with.
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: upTo(120)},
        {partitionId: "3", fromBlock: 20, reply: upTo(40)},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 121, reply: LeavePending},
        {partitionId: "3", fromBlock: 41, reply: LeavePending},
      ])

      t.expect(
        (whileOpen, sourceMock->pendingQueries),
        ~message="no bound is guessed while partition 2's query is open-ended; then the catch-up stops at 120",
      ).toEqual((
        [addressFree(51, Unbounded), catchUp(20, Unbounded)],
        [addressFree(121, Unbounded), catchUp(41, Bounded(120))],
      ))
    },
  )

  scenario->Scenario.it(
    "drops an open-ended catch-up that comes back past the block the address-free partition reached",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=20)
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: upTo(~items=[handled->eventAt(60)], 120)},
        {partitionId: "3", fromBlock: 20, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 20, reply: upTo(~items=[handled->eventAt(60)], 150)},
        {partitionId: "2", reply: LeavePending},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (handled, sourceMock->nextQueries),
        ~message="the overlap both partitions fetched is processed once, and the catch-up is gone",
      ).toEqual(([60], [addressFree(121, Bounded(210))]))
    },
  )

  scenario->Scenario.it(
    "keeps a catch-up unbounded when its own response lands first, then bounds it at what the address-free query covered",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=20)
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 20, reply: upTo(~items=[handled->eventAt(60)], 80)},
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 81, reply: LeavePending},
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
      ])
      let aheadOfAddressFree = sourceMock->pendingQueries

      // Routed before address 3 existed, partition 2's query carries none of
      // its events.
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: upTo(120)},
        {partitionId: "3", fromBlock: 81, reply: upTo(100)},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 101, reply: LeavePending},
        {partitionId: "2", fromBlock: 121, reply: LeavePending},
      ])
      let bounded = sourceMock->pendingQueries
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 101, reply: upTo(120)},
        {partitionId: "2", fromBlock: 121, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (aheadOfAddressFree, bounded, handled, sourceMock->pendingQueries),
        ~message="the catch-up runs past partition 2 unbounded, stops at the 120 it covered, and block 60 is processed once",
      ).toEqual((
        [addressFree(51, Unbounded), catchUp(81, Unbounded)],
        [addressFree(121, Unbounded), catchUp(101, Bounded(120))],
        [60],
        [addressFree(121, Unbounded)],
      ))
    },
  )

  scenario->Scenario.it(
    "keeps a catch-up that ran past the address-free frontier until its last query lands",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let handled = []
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=20)
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 20, reply: upTo(80)},
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
      ])
      // Partition 2 settles at 70, below the 80 the catch-up already passed,
      // while the catch-up's next query is still out.
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 81, reply: LeavePending},
        {partitionId: "2", fromBlock: 51, reply: upTo(70)},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 81, reply: upTo(~items=[handled->eventAt(85)], 90)},
        {partitionId: "2", fromBlock: 71, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 71, reply: upTo(~items=[handled->eventAt(85)], 200)},
      ])
      await sourceMock.expectItemsQueries([{partitionId: "2", reply: LeavePending}])
      await indexer.waitUntilIdle()

      t.expect(
        (handled, sourceMock->nextQueries),
        ~message="the catch-up's last response still lands, its event is processed once, and the catch-up asks nothing more",
      ).toEqual(([85], [addressFree(201, Bounded(236))]))
    },
  )

  scenario->Scenario.it(
    "catches an address up over the range the address-free query has in flight above its frontier",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      // Registered at 60, above partition 2's frontier of 50, but partition 2's
      // query from 51 went out before the address existed.
      await sourceMock->registerWhileAddressFreeQueryIsOpen(~registeredAt=60)
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 51, reply: LeavePending},
        {partitionId: "3", reply: LeavePending},
      ])

      t.expect(sourceMock->pendingQueries).toEqual([
        addressFree(51, Unbounded),
        catchUp(60, Unbounded),
      ])
    },
  )

  scenario->Scenario.it(
    "adds no catch-up for an address registered above an idle address-free partition",
    ~sources=[{chain: 1337}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      // Partition 2 fetches to the head it knows, 50, and waits there.
      await sourceMock->collapseGravatar(~height=50)
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 1, reply: upTo(50)},
        {partitionId: "0", fromBlock: 6, reply: LeavePending},
      ])
      // Partition 0's query comes back past that head, registering address 3
      // at 60.
      await sourceMock.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 6,
          reply: Respond({
            items: [registerAt(60, [address(3)])],
            latestFetchedBlockNumber: 100,
            knownHeight: 100,
          }),
        },
      ])
      await sourceMock.expectItemsQueries([{partitionId: "2", fromBlock: 51, reply: LeavePending}])
      await indexer.waitUntilIdle()

      t.expect(
        sourceMock->pendingQueries,
        ~message="partition 2 covers block 60 going forward on its own",
      ).toEqual([addressFree(51, Unbounded)])
    },
  )
})
