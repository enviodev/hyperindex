open Vitest

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

type query = {
  partitionId: string,
  fromBlock: int,
  toBlock: MockSource.toBlock,
  addresses: array<string>,
  clientFilteredContracts: option<array<string>>,
}

let pendingQueries = (sourceMock: MockSource.t) =>
  sourceMock.pendingItemsQueries->Array.map(query => {
    partitionId: query.partitionId,
    fromBlock: query.fromBlock,
    toBlock: query.toBlock,
    addresses: query->MockSource.addresses->Array.map(Address.toString),
    clientFilteredContracts: (query->MockSource.selection).clientFilteredContracts,
  })

let nftFactory = (~partitionId="0", fromBlock) => {
  partitionId,
  fromBlock,
  toBlock: Unbounded,
  addresses: ["0x00000000000000000000000000000000000000ff"],
  clientFilteredContracts: None,
}

let addressFree = (~partitionId, fromBlock) => {
  partitionId,
  fromBlock,
  toBlock: Unbounded,
  addresses: [],
  clientFilteredContracts: Some(["Gravatar"]),
}

let catchUp = (~partitionId, fromBlock, toBlock) => {
  partitionId,
  fromBlock,
  toBlock,
  addresses: [address(3)->Address.toString],
  clientFilteredContracts: None,
}

let hashes = (blockNumbers, ~validUpTo) =>
  blockNumbers->Array.map((blockNumber): BlockStore.inputBlock => {
    blockNumber,
    blockHash: blockNumber <= validUpTo
      ? `0x${blockNumber->Int.toString}`
      : `0x${blockNumber->Int.toString}a`,
    blockTimestamp: blockNumber,
  })

// Partition 0 registers two dynamic Gravatar addresses at block 3, crossing
// the threshold of 1, so address-free partition 2 fetches Gravatar. Both reach
// the reorg window at 500, where partition 2 fetches to 650 and registers
// address 3 at 620: catch-up partition 3 fetches it over [620, 650].
let registerInReorgWindow = async (sourceMock: MockSource.t) => {
  sourceMock.resolveGetHeightOrThrow(2000)
  await sourceMock.expectItemsQueries([
    {
      partitionId: "0",
      fromBlock: 1,
      reply: Respond({
        items: [registerAt(3, [address(1), address(2)])],
        latestFetchedBlockNumber: 5,
      }),
    },
  ])
  await sourceMock.expectItemsQueries([
    {partitionId: "2", fromBlock: 1, toBlock: Bounded(499), reply: Respond({items: []})},
    {partitionId: "0", fromBlock: 6, toBlock: Bounded(499), reply: Respond({items: []})},
  ])
  await sourceMock.expectItemsQueries([
    {
      partitionId: "2",
      fromBlock: 500,
      reply: Respond({
        items: [registerAt(620, [address(3)])],
        blocks: [{blockNumber: 630}],
        latestFetchedBlockNumber: 650,
      }),
    },
    {partitionId: "0", fromBlock: 500, reply: LeavePending},
  ])
}

// Partition 2's next response finds block 650 re-orged.
let reorgAbove650 = MockSource.Respond({
  items: [],
  latestFetchedBlockNumber: 700,
  prevRangeLastBlock: {blockNumber: 650, blockHash: "0x650a"},
})

describe("FetchState client-side filtering across a rollback", () => {
  scenario->Scenario.it(
    "keeps a catch-up the rollback leaves behind, capped at the rollback target, with the contract still client-side",
    ~sources=[{chain: 1337, methods}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerInReorgWindow
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 620, toBlock: Bounded(650), reply: LeavePending},
        {partitionId: "2", fromBlock: 651, reply: reorgAbove650},
      ])
      await sourceMock.expectBlockHashLookup({
        blockNumbers: [620, 630],
        reply: [620, 630]->hashes(~validUpTo=630),
      })
      await indexer.getRollbackReadyPromise()
      await sourceMock.expectItemsQueries([
        {partitionId: "2", fromBlock: 620, reply: LeavePending},
        {partitionId: "1", fromBlock: 631, reply: LeavePending},
        {partitionId: "0", fromBlock: 500, reply: LeavePending},
      ])

      t.expect(
        sourceMock->pendingQueries,
        ~message="the rebuilt partitions keep address 3's catch-up below 630 and Gravatar address-free above it",
      ).toEqual([
        // Dispatched before the rollback, and voided by it.
        nftFactory(500),
        catchUp(~partitionId="3", 620, Bounded(650)),
        nftFactory(500),
        catchUp(~partitionId="2", 620, Bounded(630)),
        addressFree(~partitionId="1", 631),
      ])
    },
  )

  scenario->Scenario.it(
    "folds a catch-up the rollback leaves level with the address-free partition back into it",
    ~sources=[{chain: 1337, methods}],
    ~clientFilterAddressThreshold=1,
    ~maxAddrInPartition=10,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      await sourceMock->registerInReorgWindow
      await sourceMock.expectItemsQueries([
        {
          partitionId: "3",
          fromBlock: 620,
          reply: Respond({items: [], blocks: [{blockNumber: 640}], latestFetchedBlockNumber: 645}),
        },
        {partitionId: "2", fromBlock: 651, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {partitionId: "3", fromBlock: 646, reply: LeavePending},
        {partitionId: "2", fromBlock: 651, reply: reorgAbove650},
      ])
      await sourceMock.expectBlockHashLookup({
        blockNumbers: [619, 620, 630, 640, 645],
        reply: [619, 620, 630, 640, 645]->hashes(~validUpTo=640),
      })
      await indexer.getRollbackReadyPromise()
      await sourceMock.expectItemsQueries([
        {partitionId: "1", fromBlock: 641, reply: LeavePending},
        {partitionId: "0", fromBlock: 500, reply: LeavePending},
      ])

      t.expect(
        sourceMock->pendingQueries,
        ~message="rolled back to 640, the catch-up has nothing left to cover",
      ).toEqual([
        // Dispatched before the rollback, and voided by it.
        nftFactory(500),
        catchUp(~partitionId="3", 646, Bounded(650)),
        nftFactory(500),
        addressFree(~partitionId="1", 641),
      ])
    },
  )
})
