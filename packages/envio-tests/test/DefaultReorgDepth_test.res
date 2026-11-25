open Vitest

// Sequencer-ordered blocks are only a promise until their batch is final on the
// parent chain, so a rollup needs the same reorg window as any other chain.
let chainIds = [1, 10, 5115, 42161, 42170, 421614, 11155420]

let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: default-reorg-depth
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
${chainIds
    ->Array.map(chainId =>
      `  - id: ${chainId->Int.toString}
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"`
    )
    ->Array.join("\n")}
`,
  ~schema=`
type Account {
  id: ID!
}
`,
)

describe("Default max_reorg_depth", () => {
  it("is the same for Arbitrum, Optimism and Citrea chains as for any other", t => {
    t.expect(
      config.chainMap
      ->ChainMap.values
      ->Array.map(chain => (chain.id->ChainId.toInt, chain.maxReorgDepth))
      ->Array.toSorted(((a, _), (b, _)) => Int.compare(a, b)),
    ).toEqual(chainIds->Array.map(chainId => (chainId, 199)))
  })
})
