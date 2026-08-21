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

      let gravatarAddress =
        "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"->Address.Evm.fromStringOrThrow
      let nftFactoryAddress =
        "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"->Address.Evm.fromStringOrThrow

      // The chain's ground truth: one event per static contract at block 50,000.
      // A query delivers an event when it covers the block and carries the
      // emitter's address — exactly what a real source would return.
      let worldEvents = [
        (gravatarAddress, 50_000, 0, "gravatar-50000"),
        (nftFactoryAddress, 50_000, 1, "nftFactory-50000"),
      ]
      let itemsFor = (call: MockSource.getItemsOrThrowCall, ~toBlock) => {
        let addresses = call.payload->MockSource.CallPayload.addresses
        worldEvents->Array.filterMap(((address, blockNumber, logIndex, id)) =>
          if (
            addresses->Array.includes(address) &&
            call.payload["fromBlock"] <= blockNumber &&
            blockNumber <= toBlock
          ) {
            Some(({blockNumber, logIndex, handler: record(id)}: MockSource.itemMock))
          } else {
            None
          }
        )
      }
      let resolveTo = (call: MockSource.getItemsOrThrowCall, toBlock) =>
        call.resolve(call->itemsFor(~toBlock), ~latestFetchedBlockNumber=toBlock)

      await Utils.delay(0)
      let find = (p, ~fromBlock) =>
        sourceMock.getItemsOrThrowCalls
        ->Array.find(c => c.payload["p"] === p && c.payload["fromBlock"] === fromBlock)
        ->Option.getOrThrow(
          ~message=`Expected a pending query for partition ${p} from block ${fromBlock->Int.toString}`,
        )

      let settle = async () => {
        await Utils.delay(0)
        await Utils.delay(0)
        await Utils.delay(0)
      }

      sourceMock.resolveGetHeightOrThrow(100_000)
      await settle()

      // Partition "0" holds both static config addresses (Gravatar + NftFactory)
      // merged together — the mixed partition this test splits.
      t.expect(
        sourceMock.getItemsOrThrowCalls->Array.map(c => c.payload),
        ~message="initial query for the merged static partition",
      ).toEqual([{"fromBlock": 1, "toBlock": Some(99_800), "retry": 0, "p": "0"}])

      // Seed items at blocks 2-9 sit below the dynamic partition's start block,
      // so they process immediately and give the chain a density signal. The
      // registration at block 10 creates the SimpleNft partition — the sibling
      // whose later response delivers the NftFactory registration while
      // partition "0" is idle.
      find("0", ~fromBlock=1).resolve(
        [
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
                "0x1111111111111111111111111111111111111111"->Address.Evm.fromStringOrThrow,
              )
            },
          },
        ],
        ~latestFetchedBlockNumber=24_000,
      )
      await indexer.getBatchWritePromise()

      find("2", ~fromBlock=10).resolve([], ~latestFetchedBlockNumber=20_000)
      await settle()

      // The SimpleNft response delivers the first NftFactory dynamic
      // registration while partition "0" is idle (the SimpleNft probe holds the
      // whole fetch budget, so "0" has no query in flight). This splits "0":
      // it keeps Gravatar, the new partition "3" takes the static NftFactory
      // address, and partition "4" backfills the fresh address up to the
      // split's frontier.
      find("2", ~fromBlock=20_001).resolve(
        [
          {
            blockNumber: 20_050,
            logIndex: 0,
            contractRegister: async args => {
              let context = args->registerContext
              context.chain["NftFactory"].add(
                "0x2222222222222222222222222222222222222222"->Address.Evm.fromStringOrThrow,
              )
            },
          },
        ],
        ~latestFetchedBlockNumber=45_000,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        sourceMock.getItemsOrThrowCalls
        ->Array.map(
          c => (
            c.payload["p"],
            c.payload["fromBlock"],
            c.payload->MockSource.CallPayload.addresses->Array.length,
          ),
        )
        // Two partitions share fromBlock 24,001, and their relative order is
        // an enqueue detail this test doesn't describe — break the tie on id.
        ->Array.toSorted(((pA, a, _), (pB, b, _)) =>
          a === b ? String.compare(pA, pB) : Int.compare(a, b)
        ),
        ~message="the registration splits partition '0' into Gravatar ('0') and NftFactory ('3')",
      ).toEqual([
        ("4", 20_050, 1),
        ("0", 24_001, 1),
        ("3", 24_001, 2),
        ("2", 45_001, 1),
        ("2", 80_985, 1),
      ])

      // Clear the SimpleNft partition and the bounded backfill so only the two
      // split halves stay in play.
      resolveTo(find("2", ~fromBlock=45_001), 80_984)
      await settle()
      resolveTo(find("2", ~fromBlock=80_985), 99_800)
      await settle()
      resolveTo(find("4", ~fromBlock=20_050), 24_000)
      await indexer.getBatchWritePromise()

      // Both split halves respond partially, putting them at different
      // frontiers: Gravatar at 40,000, NftFactory at 30,000.
      resolveTo(find("0", ~fromBlock=24_001), 40_000)
      await settle()
      resolveTo(find("3", ~fromBlock=24_001), 30_000)
      await settle()

      // Gravatar's next query (40,001..) resolves first — for Gravatar's address
      // only, delivering its block-50,000 event. NftFactory's next query
      // (30,001..) then lands exactly at 40,000. With the aliased queue,
      // NftFactory's consume pass eats Gravatar's fetched result and jumps its
      // frontier to 60,000 — blocks 40,001-60,000 are never queried with the
      // NftFactory addresses, so its block-50,000 event is lost.
      resolveTo(find("0", ~fromBlock=40_001), 60_000)
      await settle()
      resolveTo(find("3", ~fromBlock=30_001), 40_000)
      await settle()

      // Drain: resolve every remaining query to its full range, delivering
      // whatever world events it legitimately covers.
      let rounds = ref(0)
      while rounds.contents < 20 && sourceMock.getItemsOrThrowCalls->Array.length > 0 {
        switch sourceMock.getItemsOrThrowCalls->Array.get(0) {
        | Some(call) => resolveTo(call, call.payload["toBlock"]->Option.getOr(99_800))
        | None => ()
        }
        await settle()
        rounds := rounds.contents + 1
      }
      await indexer.getBatchWritePromise()

      t.expect(
        processed->Array.toSorted(String.compare),
        ~message="both static contracts' block-50,000 events are fetched and processed",
      ).toEqual(["gravatar-50000", "nftFactory-50000"])
    },
  )
})
