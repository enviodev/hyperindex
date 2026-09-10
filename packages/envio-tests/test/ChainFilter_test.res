open Vitest

// `envio start --chain` runs one indexer per chain against a schema that
// `db-migrate up` already created for every chain. The filter narrows the
// config the process drives without touching the contract mapping, whose ids
// have to keep matching the ones the migration stored.

let perChainSchema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let crossChainSchema = `
type Counter {
  id: ID!
  count: BigInt!
}
type GlobalCounter @crossChain {
  id: ID!
  count: BigInt!
}
`

let configYaml = `
name: chain-filter
disable_default_cross_chain: true
contracts:
  - name: Counters
    events:
      - event: Bumped(uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Counters
        address: "0x1111111111111111111111111111111111111111"
  - id: 137
    start_block: 0
    contracts:
      - name: Counters
        address: "0x2222222222222222222222222222222222222222"
`

let config = InternalTestIndexer.fromUserApi(~configYaml, ~schema=perChainSchema).config
let chainId = id => id->ChainId.normalizeOrThrow

describe("Config.filterChains", () => {
  it("Narrows the chain map and keeps the contract mapping whole", t => {
    let filtered = config->Config.filterChains(~chainIds=[chainId(137)])
    t.expect((
      filtered.chainMap->ChainMap.keys->Array.map(ChainId.toString),
      filtered.defaultChain->Option.map(chain => chain.id->ChainId.toString),
      filtered.contractMapping->ContractMapping.isEqual(config.contractMapping),
    )).toEqual((["137"], Some("137"), true))
  })

  it("Keeps every chain when the selection names them all", t => {
    let filtered = config->Config.filterChains(~chainIds=[chainId(1), chainId(137)])
    t.expect(filtered.chainMap->ChainMap.keys->Array.map(ChainId.toString)).toEqual(["1", "137"])
  })

  it("Rejects a chain the config doesn't declare", t => {
    t->toThrowErrorEqual(
      () => config->Config.filterChains(~chainIds=[chainId(42)]),
      `Chain 42 is not configured, so \`envio start --chain 42\` has nothing to index. Configured chains: 1, 137.`,
    )
  })

  it("Rejects an empty selection", t => {
    t->toThrowErrorEqual(
      () => config->Config.filterChains(~chainIds=[]),
      `\`envio start --chain\` needs at least one chain to index.`,
    )
  })

  it("Names a `--chain` run by the flag's presence, not by how many it narrowed", t => {
    // The precondition `--chain` carries — that the migration already built the
    // schema for every chain — holds just as much when the flag happens to name
    // all of them. A count comparison would call that an unfiltered run.
    let before = Config.hasChainFilter()
    Config.setActiveChains([chainId(1), chainId(137)])
    let namingAll = Config.hasChainFilter()
    Config.setActiveChains([])
    t.expect((before, namingAll, Config.hasChainFilter())).toEqual((false, true, false))
  })

  it("Reports a wholly cross-chain schema without listing every entity", t => {
    let crossChain = InternalTestIndexer.fromUserApi(
      ~configYaml=configYaml->String.replace("disable_default_cross_chain: true\n", ""),
      ~schema=perChainSchema,
    ).config
    t->toThrowErrorEqual(
      () => crossChain->Config.filterChains(~chainIds=[chainId(1)]),
      `\`envio start --chain\` needs every entity to be per-chain, because chains indexed in separate processes can't share a checkpoint sequence. Every entity in this schema is cross-chain, because config.yaml doesn't set \`disable_default_cross_chain: true\`. Set it, then run every chain in its own process.`,
    )
  })

  it("Rejects a schema that shares entities across chains", t => {
    let crossChain = InternalTestIndexer.fromUserApi(
      ~configYaml,
      ~schema=crossChainSchema,
    ).config
    t->toThrowErrorEqual(
      () => crossChain->Config.filterChains(~chainIds=[chainId(1)]),
      `\`envio start --chain\` needs every entity to be per-chain, because chains indexed in separate processes can't share a checkpoint sequence. Entities shared across chains: GlobalCounter. Drop \`@crossChain\` from them, or run every chain in one process.`,
    )
  })
})
