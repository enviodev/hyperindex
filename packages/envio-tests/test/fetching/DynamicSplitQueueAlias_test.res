open Vitest

// A dynamic registration for a contract whose config address shares a group
// with another contract's must not leave a range of either contract
// unfetched: each static contract's event past the registration is fetched and
// processed, whatever frontiers the requests reach on the way.
//
// Reported as a ~1M-block blackout of a single contract group on a fresh
// cloud deployment (envio 3.5.0-rc.0) while every other contract group in
// the same window stayed intact.
//
// Gravatar and NftFactory have static addresses and share a group;
// SimpleNft and TestEvents only have addresses once registered.
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
  // A dynamically registered address is only fetched when a registration
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

describe("Dynamic registration next to a mixed-contract group", () => {
  scenario->Scenario.it(
    "does not skip a range of either contract in the mixed group",
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
      let respondTo = (~address, ~fromBlock, ~toBlock): MockSource.expectedItemsQuery => {
        address,
        fromBlock,
        reply: RespondWith(
          query => {items: query->itemsFor(~toBlock), latestFetchedBlockNumber: toBlock},
        ),
      }
      let respondInFull = (query: MockSource.pendingItemsQuery): MockSource.expectedItemsQuery => {
        where: pending => pending === query,
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
      let summarize = queries =>
        queries
        ->Array.map((query: MockSource.pendingItemsQuery) => (
          query.fromBlock,
          query->MockSource.addresses->Array.length,
        ))
        ->Array.toSorted(((a, aCount), (b, bCount)) =>
          a === b ? Int.compare(aCount, bCount) : Int.compare(a, b)
        )

      sourceMock.resolveGetHeightOrThrow(100_000)

      // The mixed group fetches its whole range to 99,800 at once and sits
      // idle there: the SimpleNft group holds the chain's frontier back, so it
      // doesn't wait for a new block either.
      //
      // The seed items give the chain a density signal; the registration at
      // block 10 gives SimpleNft a group of its own, whose later response
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

      // The first NftFactory dynamic registration lands while the mixed group
      // is idle. The group holds two contracts, so it is sealed: the fresh
      // address gets a group of its own from its registration block.
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

      // A new head sets the mixed group querying past 99,800.
      await sourceMock.expectItemsQueries([
        {
          fromBlock: 45_001,
          reply: Respond({items: [], latestFetchedBlockNumber: 80_984, knownHeight: 200_000}),
        },
        {fromBlock: 80_985, reply: LeavePending},
        {fromBlock: 20_050, reply: LeavePending},
      ])
      await indexer.waitUntilIdle()
      let afterRegistration = sourceMock.pendingItemsQueries->summarize

      // The mixed group responds partially, short of the static contracts'
      // events at 150,000.
      await sourceMock.expectItemsQueries([
        respondTo(~address=gravatarAddress->Address.toString, ~fromBlock=99_801, ~toBlock=140_000),
        {
          where: query => !(query->MockSource.addresses->Array.includes(gravatarAddress)),
          reply: LeavePending,
        },
      ])
      await indexer.waitUntilIdle()

      // Resolve every remaining query to its full range, delivering whatever
      // world events it legitimately covers, until the chain only asks past
      // 199,800.
      let isBehind = (query: MockSource.pendingItemsQuery) => query.fromBlock <= 199_800
      let rounds = ref(0)
      while sourceMock.pendingItemsQueries->Array.some(isBehind) && rounds.contents < 50 {
        rounds := rounds.contents + 1
        await sourceMock.expectItemsQueries(
          sourceMock.pendingItemsQueries->Array.map(query =>
            query->isBehind ? respondInFull(query) : {where: pending => pending === query, reply: LeavePending}
          ),
        )
        await indexer.waitUntilIdle()
      }
      await indexer.getBatchWritePromise()

      t.expect((afterRegistration, processed->Array.toSorted(String.compare))).toEqual((
        // The NftFactory address from its registration block, SimpleNft's
        // chunks, and the mixed group past 99,800 with both static addresses.
        [(20_050, 1), (80_985, 1), (99_801, 1), (99_801, 2), (144_801, 1)],
        // Both static contracts' block-150,000 events are fetched and processed.
        ["gravatar-150000", "nftFactory-150000"],
      ))
    },
  )
})
