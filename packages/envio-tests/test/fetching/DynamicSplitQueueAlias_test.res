open Vitest

// When the first dynamic registration for a contract arrives while a
// mixed-contract partition is idle, registerDynamicContracts splits that
// contract's addresses into their own partition — but the split partition
// takes the original's mutPendingQueries array by reference. Both partitions
// then push and consume queries in the same mutable array, so one partition's
// consumeFetchedQueries can consume the other's fetched query and advance its
// own frontier over a range its addresses were never queried for. Events for
// those addresses in that range are permanently skipped.
//
// Reported as a ~1M-block blackout of a single contract group on a fresh
// cloud deployment (envio 3.5.0-rc.0) while every other contract group in
// the same window stayed intact.
//
// The partition ids this pins follow from the contract shape below: two
// contracts with static addresses that merge into partition "0", and two
// address-only-when-registered contracts.
let scenario = Scenario.make(
  ~configYaml=`
name: dynamic-split-queue-alias
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
      - name: NftFactory
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
        events:
          - event: "SimpleNftCreated(string name, string symbol, uint256 maxSupply, address contractAddress)"
      - name: SimpleNft
        events:
          - event: "Transfer(address indexed from, address indexed to, uint256 indexed tokenId)"
      - name: TestEvents
        events:
          - event: "IndexedUint(uint256 indexed num)"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
  // A dynamically registered address only gets a partition when a registration
  // depends on it, so every contract this scenario registers has to be indexed.
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async () => {});
indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "TestEvents", event: "IndexedUint" }, async () => {});
`,
)

type contractOps = {add: Address.t => unit}
type registerContext = {chain: {"SimpleNft": contractOps, "NftFactory": contractOps}}

let registerContext = (args: Internal.contractRegisterArgs) =>
  args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)

describe("Dynamic-registration partition split queue aliasing", () => {
  scenario->Scenario.it(
    "does not skip a range for the split-off contract",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~targetBufferSize=100,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let processed = []
      let record = id =>
        (async _ => processed->Array.push(id)->ignore)->(
          Utils.magic: (Internal.handlerArgs => promise<unit>) => MockSource.mockSourceHandler
        )

      // A query carries the store's canonical spelling of an emitter, which is
      // what the world's events are matched against below.
      let gravatarAddress = "0x2b2f78c5bf6d9c12ee1225d5f374aa91204580c3"->Address.unsafeFromString
      let nftFactoryAddress = "0xa2f6e6029638ccb484a2ccb6414499ad3e825cac"->Address.unsafeFromString

      // The chain's ground truth: one event per static contract at block
      // 150,000, past the split. A query delivers an event when it covers the
      // block and carries the emitter's address — exactly what a real source
      // would return.
      let worldEvents = [
        (gravatarAddress, 150_000, 0, "gravatar-150000"),
        (nftFactoryAddress, 150_000, 1, "nftFactory-150000"),
      ]
      let itemsFor = (query: MockSource.pendingItemsQuery, ~toBlock) => {
        let addresses = query->MockSource.addresses
        worldEvents->Array.filterMap(
          ((address, blockNumber, logIndex, id)) =>
            if (
              addresses->Array.includes(address) &&
              query.fromBlock <= blockNumber &&
              blockNumber <= toBlock
            ) {
              Some(({blockNumber, logIndex, handler: record(id)}: MockSource.itemMock))
            } else {
              None
            },
        )
      }
      // The items depend on the addresses the query carries, so the reply is
      // built from the query it matches.
      let respondTo = (partitionId, ~fromBlock, ~toBlock): MockSource.expectedItemsQuery => {
        partitionId,
        fromBlock,
        reply: RespondWith(
          query => {items: query->itemsFor(~toBlock), latestFetchedBlockNumber: toBlock},
        ),
      }
      let respondInFull = (partitionId, ~fromBlock): MockSource.expectedItemsQuery => {
        partitionId,
        fromBlock,
        reply: RespondWith(
          query => {
            let toBlock = switch query.toBlock {
            | Bounded(toBlock) => toBlock
            | Unbounded => 199_800
            }
            {items: query->itemsFor(~toBlock), latestFetchedBlockNumber: toBlock}
          },
        ),
      }

      sourceMock.resolveGetHeightOrThrow(100_000)

      // Partition "0" holds both static config addresses (Gravatar + NftFactory)
      // merged together — the mixed partition this test splits. It fetches its
      // whole range to 99,800 at once and sits idle there: the SimpleNft
      // partition holds the chain's frontier back, so it doesn't wait for a new
      // block either. It has to be idle when the registration lands: a
      // contractRegister run ends after the fetch tick of the response it came
      // in, so a partition still fetching always has its next query out by
      // then, and gets a catch-up partition instead of a split.
      //
      // The seed items give the chain a density signal; the registration at
      // block 10 creates the SimpleNft partition "2", whose later response
      // delivers the NftFactory registration.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 1,
          toBlock: Bounded(99_800),
          retryCount: 0,
          reply: Respond({
            items: [
              ...Array.fromInitializer(
                ~length=100,
                (i): MockSource.itemMock => {blockNumber: 2 + mod(i, 8), logIndex: i / 8},
              ),
              {
                blockNumber: 10,
                logIndex: 0,
                contractRegister: async args => {
                  let context = args->registerContext
                  context.chain["SimpleNft"].add(
                    "0x1111111111111111111111111111111111111111"->Address.unsafeFromString,
                  )
                },
              },
            ],
            latestFetchedBlockNumber: 99_800,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      await sourceMock.expectItemsQueries([
        {
          fromBlock: 10,
          reply: Respond({items: [], latestFetchedBlockNumber: 20_000}),
        },
      ])
      await indexer.getBatchWritePromise()

      // The first NftFactory dynamic registration lands while partition "0" is
      // idle. This splits "0": it keeps Gravatar, the new partition "3" takes
      // the static NftFactory address, and partition "4" backfills the fresh
      // address up to the split's frontier.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 20_001,
          reply: Respond({
            items: [
              {
                blockNumber: 20_050,
                logIndex: 0,
                contractRegister: async args => {
                  let context = args->registerContext
                  context.chain["NftFactory"].add(
                    "0x2222222222222222222222222222222222222222"->Address.unsafeFromString,
                  )
                },
              },
            ],
            latestFetchedBlockNumber: 45_000,
          }),
        },
      ])
      await indexer.waitUntilIdle()

      // A new head sets both split halves querying past 99,800.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 45_001,
          reply: Respond({items: [], latestFetchedBlockNumber: 80_984, knownHeight: 200_000}),
        },
        {fromBlock: 80_985, reply: LeavePending},
        {fromBlock: 20_050, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      let afterSplit =
        sourceMock.pendingItemsQueries
        ->Array.map(
          query => (query.partitionId, query.fromBlock, query->MockSource.addresses->Array.length),
        )
        // Partitions sharing a fromBlock go out in an enqueue order this test
        // doesn't describe — break the tie on id.
        ->Array.toSorted(
          ((pA, a, _), (pB, b, _)) => a === b ? String.compare(pA, pB) : Int.compare(a, b),
        )

      // Both split halves respond partially, putting them at different
      // frontiers: Gravatar at 140,000, NftFactory at 120,000.
      await sourceMock.expectItemsQueries([
        respondTo("0", ~fromBlock=99_801, ~toBlock=140_000),
        {fromBlock: 99_801, reply: LeavePending},
        {fromBlock: 99_801, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        respondTo("3", ~fromBlock=99_801, ~toBlock=120_000),
        {fromBlock: 144_801, reply: LeavePending},
        {fromBlock: 189_801, reply: LeavePending},
        {fromBlock: 140_001, reply: LeavePending},
      ])

      // Gravatar's next query (140,001..) resolves first — for Gravatar's
      // address only, delivering its block-150,000 event. NftFactory's next
      // query (120,001..) then lands exactly at 140,000. With an aliased queue,
      // NftFactory's consume pass eats Gravatar's fetched result and jumps its
      // frontier to 160,000 — blocks 140,001-160,000 are never queried with the
      // NftFactory addresses, so its block-150,000 event is lost.
      await sourceMock.expectItemsQueries([
        respondTo("0", ~fromBlock=140_001, ~toBlock=160_000),
        {fromBlock: 120_001, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        respondTo("3", ~fromBlock=120_001, ~toBlock=140_000),
        {fromBlock: 160_001, reply: LeavePending},
      ])
      await sourceMock.expectItemsQueries([
        {fromBlock: 140_001, reply: LeavePending},
      ])

      // Resolve every remaining query to its full range, delivering whatever
      // world events it legitimately covers.
      await sourceMock.expectItemsQueries([
        respondInFull("2", ~fromBlock=80_985),
        respondInFull("4", ~fromBlock=20_050),
        respondInFull("2", ~fromBlock=99_801),
        respondInFull("2", ~fromBlock=144_801),
        respondInFull("2", ~fromBlock=189_801),
        respondInFull("0", ~fromBlock=160_001),
        respondInFull("3", ~fromBlock=140_001),
      ])
      await sourceMock.expectItemsQueries([
        respondInFull("3", ~fromBlock=176_001),
        respondInFull("4", ~fromBlock=99_801),
        respondInFull("0", ~fromBlock=196_001),
      ])
      await indexer.waitUntilIdle()
      await indexer.getBatchWritePromise()

      t.expect((afterSplit, processed->Array.toSorted(String.compare))).toEqual((
        // The registration split partition "0" into Gravatar ("0") and
        // NftFactory ("3"), each querying past 99,800 with its one address.
        [("4", 20_050, 1), ("2", 80_985, 1), ("0", 99_801, 1), ("2", 99_801, 1), ("3", 99_801, 1)],
        // Both static contracts' block-150,000 events are fetched and processed.
        ["gravatar-150000", "nftFactory-150000"],
      ))
    },
  )
})
