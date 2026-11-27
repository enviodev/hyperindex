open Vitest

// WildcardStartBlockStall_test's shape on one chain of a multichain indexer.
// The cross-chain waterfall clamps every chain to within a margin of the
// furthest-behind chain's fetch frontier, so a chain held at its start would
// read 0% forever and hold every other chain at its first margin: the wildcard's
// start block must not set the frontier the others are aligned to.
//
// https://github.com/enviodev/hyperindex/issues/1650
let scenario = Scenario.make(
  ~configYaml=`
name: wildcard-start-block-clamp
contracts:
  - name: Ledger
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 amount)"
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
      - name: Token
        start_block: 50000
  - id: 100
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Ledger
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Ledger", event: "Transfer" }, async () => {});
indexer.onEvent({ contract: "Token", event: "Transfer", wildcard: true }, async () => {});
`,
)

describe("Wildcard contract with a far-ahead start block on one chain of many", () => {
  scenario->Scenario.it(
    "does not hold the other chains behind the alignment clamp",
    ~sources=[{chain: 1337}, {chain: 100}],
    ~targetBufferSize=100,
    async (~t as _, ~indexer, ~source) => {
      let wildcardChain = source(1337)
      let plainChain = source(100)
      wildcardChain.resolveGetHeightOrThrow(100_000)
      plainChain.resolveGetHeightOrThrow(100_000)
      // Both chains start from their chain start. The wildcard registration is
      // chain-wide: on the plain chain it has no start block, so that chain
      // fetches it from the chain start too.
      //
      // The wildcard chain's response ends far past the cold target range; the
      // plain chain's ends at 20% of its range, right at the clamp a frontier
      // pinned at 0% would put on it.
      await wildcardChain.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 1,
          toBlock: Bounded(99_800),
          reply: Respond({
            items: [{blockNumber: 5, logIndex: 0}, {blockNumber: 10, logIndex: 0}],
            latestFetchedBlockNumber: 30_000,
          }),
        },
      ])
      await plainChain.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 1,
          toBlock: Bounded(99_800),
          reply: Respond({
            items: Array.fromInitializer(
              ~length=20,
              i => {
                MockSource.blockNumber: 1 + i * 1000,
                logIndex: 0,
              },
            ),
            latestFetchedBlockNumber: 20_000,
          }),
        },
        {
          partitionId: "0",
          fromBlock: 1,
          toBlock: Bounded(99_800),
          reply: Respond({items: [], latestFetchedBlockNumber: 20_000}),
        },
      ])
      await indexer.getBatchWritePromise()

      // The plain chain keeps fetching past the first alignment margin, and the
      // wildcard chain from its frontier too.
      await plainChain.expectItemsQueries([
        {partitionId: "0", fromBlock: 20_001, reply: LeavePending},
        {partitionId: "1", fromBlock: 20_001, reply: LeavePending},
      ])
      await wildcardChain.expectItemsQueries([
        {partitionId: "1", fromBlock: 30_001, toBlock: Bounded(99_800), reply: LeavePending},
      ])
    },
  )
})
