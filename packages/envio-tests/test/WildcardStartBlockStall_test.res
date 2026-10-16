open Vitest

// A wildcard contract with a `start_block` far past the chain's start, next to
// contracts that start at the chain start. The wildcard has nothing to fetch
// until its start block, and that must not hold the chain back: the chain-start
// partition keeps fetching once its responses outrun the cold target range,
// its events get processed, and the later partitions start at their start
// block. Reported on 3.9.0 as a single-chain indexer with three partitions that
// queried one of them once, then never queried again nor processed anything.
//
// https://github.com/enviodev/hyperindex/issues/1650
let scenario = Scenario.make(
  ~configYaml=`
name: wildcard-start-block-stall
contracts:
  - name: Ledger
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 amount)"
  - name: Router
    events:
      - event: "Zapped(address indexed sender, uint256 amount)"
  - name: Token
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Ledger
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
      - name: Router
        start_block: 50000
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
      - name: Token
        start_block: 50000
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Ledger", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "Router", event: "Zapped" }, async () => {});
indexer.onEvent({ contract: "Token", event: "Transfer", wildcard: true }, async () => {});
`,
)

describe("Wildcard contract with a far-ahead start block", () => {
  scenario->Scenario.it(
    "keeps fetching the address partition below the wildcard's start block",
    ~sources=[{chain: 1337}],
    ~targetBufferSize=100,
    async (~t, ~indexer, ~source) => {
      let sourceMock = source(1337)
      let processed = []
      let record = id =>
        (async _ => processed->Array.push(id)->ignore)->(
          Utils.magic: (Internal.handlerArgs => promise<unit>) => MockSource.mockSourceHandler
        )

      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=100_000)

      // Partition "0" is the wildcard, "1" holds Ledger from the chain start and
      // "2" holds Router from 50,000. Only "1" is within the cold target range;
      // it queries up to the block before "2" starts, where the two merge.
      await sourceMock.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 1,
          toBlock: Bounded(49_999),
          reply: Respond({
            items: [
              {blockNumber: 5, logIndex: 0, handler: record("ledger-5")},
              {blockNumber: 10, logIndex: 0, handler: record("ledger-10")},
            ],
            latestFetchedBlockNumber: 30_000,
          }),
        },
      ])

      // The response moved the frontier to 30,000 and gave the chain a density,
      // so its target reaches the head and every partition is in range: "1"
      // continues where its response ended, "0" and "2" start at their start
      // block.
      await sourceMock.expectItemsQueries([
        {partitionId: "0", fromBlock: 50_000, toBlock: Bounded(99_800), reply: LeavePending},
        {partitionId: "1", fromBlock: 30_001, toBlock: Bounded(49_999), reply: LeavePending},
        {partitionId: "2", fromBlock: 50_000, toBlock: Bounded(99_800), reply: LeavePending},
      ])

      await indexer.getBatchWritePromise()
      t.expect(processed, ~message="events below the fetched frontier are processed").toEqual([
        "ledger-5",
        "ledger-10",
      ])
    },
  )

  scenario->Scenario.it(
    "waits at a start block the chain has not reached instead of scanning up to it",
    ~sources=[{chain: 1337}],
    ~targetBufferSize=100,
    async (~t, ~indexer as _, ~source) => {
      let sourceMock = source(1337)
      await Scenario.resolveInitialHeight(~t, ~source=sourceMock, ~head=30_000)

      // Only the chain-start partition has anything below the head. Its
      // response also carries a head past the later start blocks.
      await sourceMock.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 1,
          toBlock: Bounded(29_800),
          reply: Respond({items: [], knownHeight: 100_000}),
        },
      ])

      // Still cold: nothing fetched yet gives the chain a density, so its target
      // stays within the cold range of the frontier and only the chain-start
      // partition is in range. It continues up to where the later ones start.
      await sourceMock.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 29_801,
          toBlock: Bounded(49_999),
          reply: Respond({items: []}),
        },
      ])

      // The later partitions start at their start block, not at the chain start.
      await sourceMock.expectItemsQueries([
        {partitionId: "0", fromBlock: 50_000, toBlock: Bounded(99_800), reply: LeavePending},
        {partitionId: "2", fromBlock: 50_000, toBlock: Bounded(99_800), reply: LeavePending},
      ])
    },
  )
})
