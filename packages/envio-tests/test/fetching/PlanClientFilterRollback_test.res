open Vitest
open ItemsQueryView.AddressFree

// Reorgs are tracked over the last 1500 blocks of a 2000-block chain, so these
// rollbacks land far more than 200 blocks below the head, where only the
// address threshold, not the near-head switch, fetches Gravatar client-side.
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-client-filter-rollback
rollback_on_reorg: true
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
    max_reorg_depth: 1500
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

let methods = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

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

let isAddressFree = (query: MockSource.pendingItemsQuery) =>
  (query->MockSource.selection).addressFreeContracts != []

let nftFactory = fromBlock => {
  fromBlock,
  toBlock: Unbounded,
  addresses: [nftFactoryConfigAddress],
  addressFreeContracts: [],
}

let addressFreeChunk = (fromBlock, toBlock) => {
  fromBlock,
  toBlock: Bounded(toBlock),
  addresses: [],
  addressFreeContracts: ["Gravatar"],
}

let catchUp = (fromBlock, toBlock) => {
  fromBlock,
  toBlock,
  addresses: [address(3)->Address.toString],
  addressFreeContracts: [],
}

let hashes = (blockNumbers, ~validUpTo) =>
  blockNumbers->Array.map((blockNumber): BufferPage.observedBlock => {
    blockNumber,
    blockHash: blockNumber <= validUpTo
      ? `0x${blockNumber->Int.toString}`
      : `0x${blockNumber->Int.toString}a`,
    blockTimestamp: blockNumber,
  })

// The config group registers two dynamic Gravatar addresses at block 3,
// crossing the threshold of 1. Its query from 6 stops short of the reorg
// window at 499, so the two are caught up by address over [3, 499] and
// Gravatar goes address-free from 500. There the address-free query fetches
// to 650 and registers address 3 at 620. Its next query, from 651, goes out
// before the registration, so address 3's catch-up waits for it: it lands at
// 700 and the catch-up goes out over [620, 700].
let registerInReorgWindow = async (sourceMock: MockSource.t) => {
  sourceMock.resolveGetHeightOrThrow(2000)
  await sourceMock.expectItemsQueries([
    {
      fromBlock: 1,
      reply: Respond({
        items: [registerAt(3, [address(1), address(2)])],
        latestFetchedBlockNumber: 5,
      }),
    },
  ])
  await sourceMock.expectItemsQueries([
    {fromBlock: 3, toBlock: Bounded(499), reply: Respond({items: []})},
    {fromBlock: 6, toBlock: Bounded(499), reply: Respond({items: []})},
  ])
  await sourceMock.expectItemsQueries([
    {
      fromBlock: 500,
      where: isAddressFree,
      reply: Respond({
        items: [registerAt(620, [address(3)])],
        blocks: [{blockNumber: 630}],
        latestFetchedBlockNumber: 650,
      }),
    },
    {fromBlock: 500, address: nftFactoryConfigAddress, reply: LeavePending},
  ])
  await sourceMock.expectItemsQueries([
    {
      fromBlock: 651,
      where: isAddressFree,
      reply: Respond({items: [], blocks: [{blockNumber: 680}], latestFetchedBlockNumber: 700}),
    },
    {fromBlock: 500, address: nftFactoryConfigAddress, reply: LeavePending},
  ])
}

// The address-free need's next response finds block 700 re-orged.
let reorgAbove700 = MockSource.Respond({
  items: [],
  latestFetchedBlockNumber: 750,
  prevRangeLastBlock: {blockNumber: 700, blockHash: "0x700a"},
})

describe("Indexing plan: client-side filtering across a rollback", () => {
  scenario->Scenario.it(
    "keeps a catch-up the rollback leaves behind, capped at the rollback target, with the contract still client-side",
    ~sources=[{chain: 1337, methods}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerInReorgWindow
      await sourceMock.expectItemsQueries([
        {fromBlock: 620, reply: LeavePending},
        {fromBlock: 701, where: isAddressFree, reply: reorgAbove700},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 500, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      // These stay pending next to the re-queries, dropped by the rollback.
      let droppedCount = sourceMock.pendingItemsQueries->Array.length
      await sourceMock.expectBlockHashLookup({
        blockNumbers: [620, 630, 650, 680],
        reply: [620, 630, 650, 680]->hashes(~validUpTo=630),
      })
      await indexer.getRollbackReadyPromise()
      await sourceMock.expectItemsQueries([
        {fromBlock: 620, toBlock: Bounded(630), reply: LeavePending},
        {fromBlock: 631, reply: LeavePending},
        {where: isAddressFree, reply: LeavePending},
        {address: nftFactoryConfigAddress, reply: LeavePending},
      ])

      // The address-free need keeps the density it learned, so it goes on in
      // chunks.
      t.expect(
        sourceMock->pendingQueries->Array.slice(~start=droppedCount),
        ~message="after the rollback address 3 is caught up below 630 and Gravatar is address-free above it",
      ).toEqual([
        nftFactory(500),
        catchUp(620, Bounded(630)),
        addressFreeChunk(631, 720),
        addressFreeChunk(721, 810),
      ])
    },
  )

  scenario->Scenario.it(
    "leaves no catch-up once the rollback puts the address-free need level with it",
    ~sources=[{chain: 1337, methods}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerInReorgWindow
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 620,
          reply: Respond({items: [], blocks: [{blockNumber: 640}], latestFetchedBlockNumber: 1060}),
        },
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 500, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 701, where: isAddressFree, reply: reorgAbove700},
        {where: isAddressFree, reply: LeavePending},
        {fromBlock: 500, address: nftFactoryConfigAddress, reply: LeavePending},
      ])
      // These stay pending next to the re-queries, dropped by the rollback.
      let droppedCount = sourceMock.pendingItemsQueries->Array.length
      await sourceMock.expectBlockHashLookup({
        blockNumbers: [619, 620, 630, 640, 650, 680],
        reply: [619, 620, 630, 640, 650, 680]->hashes(~validUpTo=640),
      })
      await indexer.getRollbackReadyPromise()
      await sourceMock.expectItemsQueries([
        {fromBlock: 641, reply: LeavePending},
        {where: isAddressFree, reply: LeavePending},
        {address: nftFactoryConfigAddress, reply: LeavePending},
      ])

      t.expect(
        sourceMock->pendingQueries->Array.slice(~start=droppedCount),
        ~message="rolled back to 640, address 3 has nothing left to catch up",
      ).toEqual([nftFactory(500), addressFreeChunk(641, 730), addressFreeChunk(731, 820)])
    },
  )
})
