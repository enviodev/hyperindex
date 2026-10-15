open Vitest

let schema = `
type Trader {
  id: ID!
  volume: BigInt!
}
enum Side {
  LONG
  SHORT
}
`

let configYaml = (~sidecar=true, ~extra) =>
  `
name: resolvers-config
${sidecar ? "sidecar:\n  contract: src/sidecar/contract.ts\n  entry: src/sidecar/index.ts" : ""}
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "NewGravatar(uint256 id, address owner, string displayName, string imageUrl)"
${extra}
`

let parse = (~sidecar=?, extra) =>
  InternalTestIndexer.fromUserApi(~configYaml=configYaml(~sidecar?, ~extra), ~schema).config

let deserializeError = detail =>
  `Failed to deserialize config. Visit the docs for more information https://docs.envio.dev/docs/configuration-file: ${detail}`

describe("resolvers: and types: in config.yaml", () => {
  it("Parses resolvers and their output types into the runtime config", t => {
    let config = parse(`
resolvers:
  topTraders:
    description: Top traders by volume
    args:
      limit: "Int!"
      chainId: Int
    output: "[TopTrader!]!"
    handler: sidecar
    timeoutMs: 3000
  tokenMeta:
    args:
      address: "String!"
    output: TokenMeta
    handler: https://api.example.com/envio/tokenMeta
types:
  TopTrader:
    address: "String!"
    volume: "BigInt!"
    rank: "Int!"
  TokenMeta:
    name: String
`)
    t.expect((config.resolvers, config.resolverTypes)).toEqual((
      dict{
        "tokenMeta": {
          Config.args: dict{"address": "String!"},
          output: "TokenMeta",
          handler: "https://api.example.com/envio/tokenMeta",
          timeoutMs: 30000,
        },
        "topTraders": {
          description: "Top traders by volume",
          args: dict{"chainId": "Int", "limit": "Int!"},
          output: "[TopTrader!]!",
          handler: "sidecar",
          timeoutMs: 3000,
        },
      },
      dict{
        "TokenMeta": dict{"name": "String"},
        "TopTrader": dict{"address": "String!", "rank": "Int!", "volume": "BigInt!"},
      },
    ))
  })

  it("Parses kind: mutation, and leaves kind out for queries", t => {
    let config = parse(`
resolvers:
  sendTip:
    kind: mutation
    args:
      to: "[String!]!"
    output: TipResult
    handler: sidecar
  wallet:
    kind: query
    output: String
    handler: sidecar
types:
  TipResult:
    id: "String!"
    recipients: "[String!]!"
`)
    t.expect(config.resolvers).toEqual(
      dict{
        "sendTip": {
          Config.kind: Mutation,
          args: dict{"to": "[String!]!"},
          output: "TipResult",
          handler: "sidecar",
          timeoutMs: 30000,
        },
        "wallet": {
          Config.args: dict{},
          output: "String",
          handler: "sidecar",
          timeoutMs: 30000,
        },
      },
    )
  })

  it("Refuses an unknown kind", t =>
    t->toThrowErrorEqual(
      () =>
        parse(`
resolvers:
  topTraders:
    kind: subscription
    output: Int
    handler: sidecar
`)->ignore,
      deserializeError(
        "unknown variant `subscription`, expected `query` or `mutation` at line 2 column 1",
      ),
    )
  )

  it("Has no resolvers when the keys are absent", t => {
    let config = parse("")
    t.expect((config.resolvers, config.resolverTypes)).toEqual((dict{}, dict{}))
  })

  it("Refuses the module path form of the resolvers preview", t =>
    t->toThrowErrorEqual(
      () => parse(`resolvers: src/resolvers`)->ignore,
      "`resolvers:` declares GraphQL fields answered by your sidecar or a webhook (a map of name to { args, output, handler }). The module path form `resolvers: src/resolvers` from the custom resolvers preview is not supported in this version.",
    )
  )

  it("Refuses unknown fields on a resolver", t =>
    t->toThrowErrorEqual(
      () =>
        parse(`
resolvers:
  topTraders:
    output: Int
    handler: sidecar
    cache: true
`)->ignore,
      deserializeError(
        "unknown field `cache`, expected one of `description`, `kind`, `args`, `output`, `handler`, `timeoutMs` at line 2 column 1",
      ),
    )
  )

  it("Reports every invalid resolver at once", t =>
    t->toThrowErrorEqual(
      () =>
        parse(`
resolvers:
  Trader_by_pk:
    output: Int
    handler: sidecar
  bad:
    args:
      filter: TopTrader
      side: Side
    output: "[Missing]"
    handler: ftp://example.com
    timeoutMs: 0
  broken:
    output: "[Int"
    handler: sidecar
types:
  Trader_bool_exp:
    id: String
  TopTrader:
    address: "String!"
`)->ignore,
      `Invalid resolvers in config.yaml:
  - resolver 'Trader_by_pk' is the by-primary-key field of entity 'Trader'
  - resolver 'bad': argument 'filter' has type 'TopTrader', but arguments take scalars or lists of scalars
  - resolver 'bad': argument 'side' has type 'Side', but arguments take scalars or lists of scalars
  - resolver 'bad': output type '[Missing]' names 'Missing', which is neither a scalar nor declared under types:
  - resolver 'bad': handler 'ftp://example.com' must be 'sidecar' or an http(s):// URL
  - resolver 'bad': timeoutMs must be greater than 0
  - resolver 'broken': output type '[Int' is not a GraphQL type
  - type 'Trader_bool_exp' is a type generated for entity 'Trader'`,
    )
  )

  it("Requires a sidecar for handler: sidecar", t =>
    t->toThrowErrorEqual(
      () =>
        parse(
          ~sidecar=false,
          `
resolvers:
  topTraders:
    output: Int
    handler: sidecar
`,
        )->ignore,
      `Invalid resolvers in config.yaml:
  - resolver 'topTraders': handler 'sidecar' needs a sidecar: block in config.yaml`,
    )
  )
})
