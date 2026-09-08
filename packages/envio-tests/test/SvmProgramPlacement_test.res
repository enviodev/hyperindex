open Vitest

let mainnetPk = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"
let devnetPk = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"

let expectParseError = (t, yaml, message) => {
  let actual = try {
    InternalTestIndexer.fromUserApi(~configYaml=yaml)->ignore
    "the parse to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }
  t.expect(actual).toBe(message)
}

/// (chain id, program names on that chain with their addresses)
let placements = (config: Config.t) =>
  config.chainMap
  ->ChainMap.values
  ->Array.map(chain => (
    chain.id->ChainId.toString,
    chain.contracts->Array.map(c => (c.name, c.addresses->Array.map(a => a->Address.toString))),
  ))

describe("SVM global program definitions", () => {
  it("places a single program id on the only chain", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~configYaml=`
name: one-chain
ecosystem: svm
chains:
  - id: solana
    start_block: 0
programs:
  - name: TokenMetadata
    program_id: ${mainnetPk}
    instructions:
      - name: update
        discriminator: "0x0f"
`,
    )
    t.expect(placements(config)).toEqual([("7565164", [("TokenMetadata", [mainnetPk])])])
  })

  it("places a per-chain mapping on each chain that names an address", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~configYaml=`
name: two-chains
ecosystem: svm
chains:
  - id: solana
    start_block: 0
  - id: solana-devnet
    start_block: 0
programs:
  - name: Everywhere
    program_id:
      solana: ${mainnetPk}
      solana-devnet: ${devnetPk}
    instructions:
      - name: update
        discriminator: "0x0f"
  - name: MainnetOnly
    program_id:
      solana: ${mainnetPk}
      solana-devnet: _
    instructions:
      - name: swap
        discriminator: "0x09"
`,
    )
    t.expect(placements(config)).toEqual([
      ("7565164", [("Everywhere", [mainnetPk]), ("MainnetOnly", [mainnetPk])]),
      ("7565165", [("Everywhere", [devnetPk])]),
    ])
  })

  it("accepts a per-chain mapping keyed by an explicit chain number", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~configYaml=`
name: numeric-chain
ecosystem: svm
chains:
  - id: 42
    start_block: 0
    hypersync_config:
      url: https://custom.hypersync.test
programs:
  - name: Custom
    program_id:
      42: ${mainnetPk}
    instructions:
      - name: update
        discriminator: "0x0f"
`,
    )
    t.expect(placements(config)).toEqual([("42", [("Custom", [mainnetPk])])])
  })

  it("rejects a single program id when the config defines several chains", t => {
    expectParseError(
      t,
      `
name: two-chains
ecosystem: svm
chains:
  - id: solana
    start_block: 0
  - id: solana-devnet
    start_block: 0
programs:
  - name: TokenMetadata
    program_id: ${mainnetPk}
    instructions: []
`,
      `Program 'TokenMetadata' gives a single \`program_id\`, but the config defines 2 chains. Name every chain instead:

  program_id:
    solana: ${mainnetPk}
    solana-devnet: _

Write \`_\` for a chain the program is not deployed on.`,
    )
  })

  it("requires the per-chain mapping to name every chain", t => {
    expectParseError(
      t,
      `
name: two-chains
ecosystem: svm
chains:
  - id: solana
    start_block: 0
  - id: solana-devnet
    start_block: 0
programs:
  - name: TokenMetadata
    program_id:
      solana: ${mainnetPk}
    instructions: []
`,
      "Program 'TokenMetadata' gives no `program_id` for chain 'solana-devnet'. Every chain the config defines must be named; write `_` for a chain the program is not deployed on.",
    )
  })

  it("reads a chain keyed by its number where the config wrote the label", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~configYaml=`
name: numeric-alias
ecosystem: svm
chains:
  - id: solana
    start_block: 0
programs:
  - name: TokenMetadata
    program_id:
      7565164: ${mainnetPk}
    instructions:
      - name: update
        discriminator: "0x0f"
`,
    )
    t.expect(placements(config)).toEqual([("7565164", [("TokenMetadata", [mainnetPk])])])
  })

  it("rejects a `program_id` key that is not a chain id", t => {
    expectParseError(
      t,
      `
name: one-chain
ecosystem: svm
chains:
  - id: solana
    start_block: 0
programs:
  - name: TokenMetadata
    program_id:
      mainnet: ${mainnetPk}
    instructions: []
`,
      "Program 'TokenMetadata' keys a `program_id` on 'mainnet', which is not a chain id: expected a cluster label or a number. Declared chains: solana.",
    )
  })

  it("rejects a chain named twice, once by label and once by number", t => {
    expectParseError(
      t,
      `
name: one-chain
ecosystem: svm
chains:
  - id: solana
    start_block: 0
programs:
  - name: TokenMetadata
    program_id:
      solana: ${mainnetPk}
      7565164: ${mainnetPk}
    instructions: []
`,
      "Program 'TokenMetadata' gives a `program_id` for chain 'solana' twice, once by label and once by number.",
    )
  })

  it("rejects a per-chain mapping naming a chain the config does not define", t => {
    expectParseError(
      t,
      `
name: two-chains
ecosystem: svm
chains:
  - id: solana
    start_block: 0
programs:
  - name: TokenMetadata
    program_id:
      solana: ${mainnetPk}
      solana-devnet: ${devnetPk}
    instructions: []
`,
      "Program 'TokenMetadata' gives a `program_id` for chain 'solana-devnet', which the config does not define. Declared chains: solana.",
    )
  })

  it("rejects a program that is deployed on no chain", t => {
    expectParseError(
      t,
      `
name: one-chain
ecosystem: svm
chains:
  - id: solana
    start_block: 0
programs:
  - name: TokenMetadata
    program_id:
      solana: _
    instructions: []
`,
      "Program 'TokenMetadata' is not deployed on any chain: every `program_id` entry is `_`.",
    )
  })

  it("rejects a bare `_` program id", t => {
    expectParseError(
      t,
      `
name: one-chain
ecosystem: svm
chains:
  - id: solana
    start_block: 0
programs:
  - name: TokenMetadata
    program_id: _
    instructions: []
`,
      "Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: programs[0].program_id: `_` marks a chain the program is not deployed on, so it is only meaningful inside a per-chain `program_id` mapping at line 9 column 17",
    )
  })

  it("ignores a configured RPC endpoint", t => {
    let {config} = InternalTestIndexer.fromUserApi(
      ~configYaml=`
name: rpc-ignored
ecosystem: svm
chains:
  - id: solana
    start_block: 0
    rpc: https://api.mainnet-beta.solana.com
programs:
  - name: TokenMetadata
    program_id: ${mainnetPk}
    instructions: []
`,
    )
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    t.expect(chain.sourceConfig).toEqual(
      Config.SvmSourceConfig({hypersync: "https://solana.hypersync.xyz"}),
    )
  })
})
