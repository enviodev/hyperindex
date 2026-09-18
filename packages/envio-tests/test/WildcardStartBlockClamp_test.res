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
    async (~t, ~indexer, ~source) => {
      let wildcardChain = source(1337)
      let plainChain = source(100)
      let queries = (sourceMock: MockSource.t) =>
        sourceMock.getItemsOrThrowCalls
        ->Array.map(c => (c.payload["p"], c.payload["fromBlock"], c.payload["toBlock"]))
        ->Array.toSorted(((pA, a, _), (pB, b, _)) =>
          a === b ? String.compare(pA, pB) : Int.compare(a, b)
        )
        ->Array.map(((p, from, to)) =>
          `${p}:${from->Int.toString}-${to->Option.mapOr("head", to => to->Int.toString)}`
        )
        ->Array.join(" ")

      wildcardChain.resolveGetHeightOrThrow(100_000)
      plainChain.resolveGetHeightOrThrow(100_000)
      await MockSource.waitItemsQuery(wildcardChain)
      await MockSource.waitItemsQuery(plainChain)
      // The wildcard registration is chain-wide: on the plain chain it has no
      // start block, so that chain fetches it from the chain start too.
      t.expect(
        (queries(wildcardChain), queries(plainChain)),
        ~message="both chains start from their chain start",
      ).toEqual(("1:1-99800", "0:1-99800 1:1-99800"))

      // The wildcard chain's response ends far past the cold target range; the
      // plain chain's ends at 20% of its range, right at the clamp a frontier
      // pinned at 0% would put on it.
      wildcardChain.resolveGetItemsOrThrow(
        [{blockNumber: 5, logIndex: 0}, {blockNumber: 10, logIndex: 0}],
        ~latestFetchedBlockNumber=30_000,
      )
      plainChain.resolveGetItemsOrThrow(
        Array.fromInitializer(~length=20, i => {MockSource.blockNumber: 1 + i * 1000, logIndex: 0}),
        ~filter=query => query["p"] === "1",
        ~latestFetchedBlockNumber=20_000,
      )
      plainChain.resolveGetItemsOrThrow(
        [],
        ~filter=query => query["p"] === "0",
        ~latestFetchedBlockNumber=20_000,
      )
      await indexer.getBatchWritePromise()

      await Scenario.waitUntil(
        () => plainChain.getItemsOrThrowCalls->Array.some(c => c.payload["fromBlock"] === 20_001),
        ~message="the plain chain to keep fetching past the first alignment margin",
        ~timeoutMs=2000.,
      )
      t.expect(
        queries(wildcardChain),
        ~message="the wildcard chain keeps fetching from its frontier too",
      ).toEqual("1:30001-99800")
    },
  )
})
