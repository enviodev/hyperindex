open Vitest

// One case per §7 row that translation can reach. Runtime-access refusals live
// in SubgraphRuntimeRefusal_test.res, where a mapping actually runs.

// What `translate` answers when nothing was refused. A case that expects the
// schema to be accepted asserts this, so an unrelated failure can't pass for
// acceptance by merely not mentioning the word under test.
let accepted = "the translation to fail, but it succeeded"

let transferAbi = `[{"type":"event","name":"Transfer","anonymous":false,"inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"value","type":"uint256","indexed":false}]}]`

// The ABI travels with every case: without it translation fails on the ABI
// rather than on what the case is about, and a case expecting acceptance would
// never see it.
let translate = (~manifest, ~schema, ~extraAbi=?) =>
  try {
    InternalTestIndexer.fromSubgraph(
      ~manifest=manifest->String.replace(
        "      abis: []",
        "      abis:\n        - name: Token\n          file: ./abis/Token.json",
      ),
      ~schema,
      ~files=Dict.fromArray([
        (
          "./abis/Token.json",
          switch extraAbi {
          | Some(entry) => transferAbi->String.replace("[{", "[" ++ entry ++ ",{")
          | None => transferAbi
          },
        ),
      ]),
    )->ignore
    accepted
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }

let baseSchema = `
type Token @entity {
  id: ID!
  total: BigInt!
}
`

let manifestWith = mapping =>
  `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis: []
${mapping}
      file: ./src/token.ts
`

let plainEventHandler = `      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer`

// A finding is identified by its headline and the location it names; the
// shared tail is asserted once, in the reporting suite below.
let expectFindingHelper = (message, t, ~headline, ~location) =>
  t.expect(
    (message->String.includes(headline), message->String.includes(`Found in ${location}.`)),
    ~message,
  ).toEqual((true, true))

describe("subgraph translation: unsupported features", () => {
  // The manifest's function has to be one the contract's ABI declares, as
  // graph-node's validation requires of a call handler.
  it("refuses a call handler whose function the ABI lacks", t => {
    translate(
      ~schema=baseSchema,
      ~manifest=manifestWith(`      callHandlers:
        - function: approve(address,uint256)
          handler: handleApprove`),
    )->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know a function "approve(address,uint256)" in the ABI.`,
      ~location=`data source "Token" → callHandlers → "handleApprove"`,
    )
  })

  it("refuses a call handler on a data source without an address, as graph-node does", t => {
    translate(
      ~schema=baseSchema,
      ~manifest=manifestWith(
        `${plainEventHandler}
      callHandlers:
        - function: transfer(address,uint256)
          handler: handleTransferCall`,
      )->String.replace("      address: \"0x1111111111111111111111111111111111111111\"\n", ""),
      ~extraAbi=`{"type":"function","name":"transfer","stateMutability":"nonpayable","inputs":[{"name":"to","type":"address"},{"name":"value","type":"uint256"}],"outputs":[{"name":"","type":"bool"}]}`,
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't know a call handler on a data source without `source.address`, which graph-node refuses as well.",
      ~location=`data source "Token" → callHandlers`,
    )
  })

  // The trace source follows static addresses, not every instance's.
  it("refuses a call-filtered block handler on a template", t => {
    let manifest =
      manifestWith(plainEventHandler) ++ `templates:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      abi: Token
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis: []
      blockHandlers:
        - handler: handlePoolBlock
          filter:
            kind: call
      file: ./src/pool.ts
`
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support call-filtered block handlers on templates yet.",
      ~location=`data source "Pool" → blockHandlers → "handlePoolBlock"`,
    )
  })

  it("refuses an unknown field in a graft block", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace(
        "dataSources:",
        "graft:\n  base: QmBase\n  block: 100\n  extra: 1\ndataSources:",
      )
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know the manifest field "extra".`,
      ~location="graft.extra",
    )
  })

  it("refuses an unknown feature", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace(
        "dataSources:",
        "features:\n  - teleportation\ndataSources:",
      )
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know the feature "teleportation".`,
      ~location="features[0]",
    )
  })

  // graph-node feeds a `kind: subgraph` data source the immutable entities
  // another deployment writes (graph/src/data_source/subgraph.rs), and that
  // deployment is published as compiled WASM, which the shim can't run.
  it("refuses subgraph composition, naming the source deployment", t => {
    let manifest = `
specVersion: 1.3.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: subgraph
    name: Transfers
    network: mainnet
    source:
      address: QmSourceDeployment
      startBlock: 0
    mapping:
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      file: ./src/mapping.ts
      entities: []
      handlers:
        - entity: Transfer
          handler: handleTransfer
`
    t.expect(
      translate(~schema=baseSchema, ~manifest),
    ).toEqual(`Envio Subgraph can't index subgraph composition (\`kind: subgraph\`).
  Found in data source "Transfers" → kind.
graph-node feeds this data source the entities deployment QmSourceDeployment writes. That deployment is published as compiled WASM, which Envio Subgraph can't run, and envio doesn't read another indexer's store. Index the source subgraph's contracts in this subgraph instead.
If you need this, please open an issue so we can look at your use case:
  https://github.com/enviodev/hyperindex/issues`)
  })

  // A substreams-powered subgraph's entities come out of a Substreams
  // package, which graph-node read from a Substreams provider until v0.42
  // removed Substreams support (NEWS.md).
  it("refuses a substreams-powered subgraph, naming its package", t => {
    let manifest = `
specVersion: 0.0.4
schema:
  file: ./schema.graphql
dataSources:
  - kind: substreams
    name: substream_test
    network: mainnet
    source:
      package:
        moduleName: graph_out
        file: substreams-test-v1.0.1.spkg
    mapping:
      kind: substreams/graph-entities
      apiVersion: 0.0.5
`
    t.expect(
      translate(~schema=baseSchema, ~manifest),
    ).toEqual(`Envio Subgraph can't index a substreams-powered subgraph (\`kind: substreams\`).
  Found in data source "substream_test" → kind.
Its entities come from the module graph_out of the Substreams package substreams-test-v1.0.1.spkg, which graph-node read from a Substreams provider until v0.42 removed Substreams support. Envio Subgraph runs AssemblyScript mappings over chain data and can't run a Substreams module.
If you need this, please open an issue so we can look at your use case:
  https://github.com/enviodev/hyperindex/issues`)
  })

  // graph-node's SPEC_VERSION_1_5_0 enables Amp data sources, whose tables
  // are SQL over an Amp dataset (graph/src/amp/manifest/data_source).
  it("refuses an Amp data source, naming its dataset", t => {
    let manifest = `
specVersion: 1.5.0
schema:
  file: ./schema.graphql
dataSources:
  - name: GRT
    kind: amp
    network: ethereum-mainnet
    source:
      address: "0xc944E90C64B2c07662A292be6244BDf05Cda44a7"
      dataset: edgeandnode/ethereum_mainnet
      tables:
        - logs
      startBlock: 11446769
    transformer:
      apiVersion: 0.0.1
      tables:
        - name: Token
          file: Token.sql
`
    t.expect(
      translate(~schema=baseSchema, ~manifest),
    ).toEqual(`Envio Subgraph can't index an Amp data source (\`kind: amp\`).
  Found in data source "GRT" → kind.
Its tables are SQL queries over the Amp dataset edgeandnode/ethereum_mainnet, which only an Amp server answers. Envio Subgraph runs AssemblyScript mappings over chain data.
If you need this, please open an issue so we can look at your use case:
  https://github.com/enviodev/hyperindex/issues`)
  })

  it("accepts specVersion 1.5.0 on an ethereum data source", t => {
    t.expect(
      translate(
        ~schema=baseSchema,
        ~manifest=manifestWith(plainEventHandler)->String.replace(
          "specVersion: 0.0.5",
          "specVersion: 1.5.0",
        ),
      ),
    ).toEqual(accepted)
  })

  // graph-node's ethereum UnresolvedMapping keeps `kind` and `language` as
  // free strings and never reads them (chain/ethereum/src/data_source.rs), and
  // graph-cli's manifest schema types them `String`: rethink-finance writes
  // `kind: ethereum/call`, an autonolas subgraph `language:
  // wassm/assemblyscript`, and both deploy.
  it("accepts any mapping kind and language, which graph-node never reads", t => {
    t.expect(
      translate(
        ~schema=baseSchema,
        ~manifest=manifestWith(plainEventHandler)
        ->String.replace("kind: ethereum/events", "kind: ethereum/call")
        ->String.replace("language: wasm/assemblyscript", "language: wassm/assemblyscript"),
      ),
    ).toEqual(accepted)
  })

  it("refuses a NEAR subgraph as one it can't index", t => {
    let manifest =
      manifestWith(plainEventHandler)
      ->String.replace("kind: ethereum/contract", "kind: near")
      ->String.replace("network: mainnet", "network: near-mainnet")
    t.expect(
      translate(~schema=baseSchema, ~manifest),
    ).toEqual(`Envio Subgraph can't index a NEAR subgraph (\`kind: near\`).
  Found in data source "Token" → kind.
Envio Subgraph runs subgraphs on EVM chains, whose blocks and logs it reads; NEAR's aren't among them.
If you need this, please open an issue so we can look at your use case:
  https://github.com/enviodev/hyperindex/issues`)
  })

  it("accepts a topic filter on an address", t => {
    let message = translate(
      ~schema=baseSchema,
      ~manifest=manifestWith(`      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
          topic1:
            - "0x0000000000000000000000000000000000000000000000000000000000000001"`),
    )
    t.expect(message).toEqual(accepted)
  })

  it("carries GraphQL interfaces through", t => {
    let message = translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
interface Named {
  id: ID!
  name: String!
}

type Token implements Named @entity {
  id: ID!
  name: String!
}
`,
    )
    t.expect(message).toEqual(accepted)
  })

  it("accepts a list of booleans", t => {
    let message = translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity {
  id: ID!
  flags: [Boolean!]!
}
`,
    )
    t.expect(message).toEqual(accepted)
  })

  // envio's store can't hold these; its own schema error would tell the user to
  // change a schema graph-node accepts, and not say where.
  it("refuses a list whose elements can be null", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity {
  id: ID!
  grid: [[Int!]]!
}
`,
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support nested lists whose elements can be null, like [[Int!]] yet.",
      ~location="schema.graphql → Token.grid",
    )
  })

  it("refuses a list of timestamps", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity {
  id: ID!
  at: [Timestamp!]!
}
`,
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support lists of Timestamp yet.",
      ~location="schema.graphql → Token.at",
    )
  })

  // What the translation doesn't anticipate still reaches envio's own checks;
  // the message says so, and where to take it.
  it("frames an error from envio's own checks", t => {
    let message = translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type pool @entity {
  id: ID!
}

type Pool @entity {
  id: ID!
}
`,
    )
    t.expect(
      (
        message->String.startsWith(
          "Envio Subgraph translated this subgraph, but envio can't index the result:",
        ),
        message->String.includes("pnpm add -D envio@subgraph"),
      ),
      ~message,
    ).toEqual((true, true))
  })

  it("refuses a timeseries without a timestamp", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity(timeseries: true) {
  id: Int8!
  total: BigInt!
}
`,
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't know the timeseries Token without a Timestamp `timestamp` field.",
      ~location="schema.graphql → type Token",
    )
  })
})

describe("subgraph translation: unknown things", () => {
  it("refuses an unknown manifest field", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace(
        "dataSources:",
        "speVersion: 0.0.5\ndataSources:",
      )
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know the manifest field "speVersion".`,
      ~location="speVersion",
    )
  })

  it("refuses an unknown data source kind", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace(
        "kind: ethereum/contract",
        "kind: ethereum/teapot",
      )
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know the data source kind "ethereum/teapot".`,
      ~location=`data source "Token" → kind`,
    )
  })

  it("refuses an unknown feature name", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace(
        "dataSources:",
        "features:\n  - timeTravel\ndataSources:",
      )
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know the feature "timeTravel".`,
      ~location="features[0]",
    )
  })

  // graph-node reads `nonDeterministicIpfs` as `ipfsOnEthereumContracts`
  // (`#[serde(alias)]` in graph/src/data/subgraph/features.rs); the VeBetter
  // DAO subgraph declares it.
  it("accepts the feature nonDeterministicIpfs, graph-node's older name", t => {
    t.expect(
      translate(
        ~schema=baseSchema,
        ~manifest=manifestWith(plainEventHandler)->String.replace(
          "dataSources:",
          "features:\n  - nonDeterministicIpfs\ndataSources:",
        ),
      ),
    ).toEqual(accepted)
  })

  it("accepts specVersion 0.0.2", t => {
    let {config} = InternalTestIndexer.fromSubgraph(
      ~schema=baseSchema,
      ~manifest=manifestWith(plainEventHandler)
      ->String.replace("specVersion: 0.0.5", "specVersion: 0.0.2")
      ->String.replace(
        "      abis: []",
        "      abis:\n        - name: Token\n          file: ./abis/Token.json",
      ),
      ~files=Dict.fromArray([("./abis/Token.json", transferAbi)]),
    )
    t.expect(config.chainMap->ChainMap.keys->Array.length).toEqual(1)
  })

  // graph-node's SPEC_VERSION_1_4_0 (graph/src/data/subgraph/api_version.rs)
  // only lets a declared call read a struct field of an event parameter.
  // Declared calls warm graph-node's call cache ahead of the handler; the
  // handler's own calls give the same answers without that cache.
  it("accepts specVersion 1.4.0, whose declared calls may read a struct field", t => {
    let {config} = InternalTestIndexer.fromSubgraph(
      ~schema=baseSchema,
      ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${FreePort.pick()}`)]),
      ~manifest=manifestWith(
        `${plainEventHandler}
          calls:
            balance: Token[event.address].balanceOf(event.params.order.owner)`,
      )
      ->String.replace("specVersion: 0.0.5", "specVersion: 1.4.0")
      ->String.replace(
        "      abis: []",
        "      abis:\n        - name: Token\n          file: ./abis/Token.json",
      ),
      ~files=Dict.fromArray([("./abis/Token.json", transferAbi)]),
    )
    t.expect(config.chainMap->ChainMap.keys->Array.length).toEqual(1)
  })

  // GRAPH_MAX_API_VERSION defaults to 0.0.10 (graph/src/env/mappings.rs); the
  // version adds the `ethereum.decodeParams` host function and gates nothing
  // else.
  it("accepts apiVersion 0.0.10, the newest graph-node runs", t => {
    t.expect(
      translate(
        ~schema=baseSchema,
        ~manifest=manifestWith(plainEventHandler)->String.replace(
          "apiVersion: 0.0.7",
          "apiVersion: 0.0.10",
        ),
      ),
    ).toEqual(accepted)
  })

  it("maps network hyperevm to chain 999", t => {
    let {config} = InternalTestIndexer.fromSubgraph(
      ~schema=baseSchema,
      ~manifest=manifestWith(plainEventHandler)
      ->String.replace("network: mainnet", "network: hyperevm")
      ->String.replace(
        "      abis: []",
        "      abis:\n        - name: Token\n          file: ./abis/Token.json",
      ),
      ~files=Dict.fromArray([("./abis/Token.json", transferAbi)]),
    )
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    t.expect(chain.id->ChainId.toString).toEqual("999")
  })

  it("maps network ethereum to chain 1", t => {
    let {config} = InternalTestIndexer.fromSubgraph(
      ~schema=baseSchema,
      ~manifest=manifestWith(plainEventHandler)
      ->String.replace("network: mainnet", "network: ethereum")
      ->String.replace(
        "      abis: []",
        "      abis:\n        - name: Token\n          file: ./abis/Token.json",
      ),
      ~files=Dict.fromArray([("./abis/Token.json", transferAbi)]),
    )
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    t.expect(chain.id->ChainId.toString).toEqual("1")
  })

  it("refuses a specVersion newer than it understands", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace("specVersion: 0.0.5", "specVersion: 9.9.9")
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know the manifest specVersion "9.9.9".`,
      ~location="specVersion",
    )
  })

  it("refuses an apiVersion newer than it understands", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace("apiVersion: 0.0.7", "apiVersion: 0.1.0")
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know the graph-ts apiVersion "0.1.0".`,
      ~location=`data source "Token" → mapping → apiVersion`,
    )
  })

  // graph-node ignores a directive it doesn't define, so subgraphs carry
  // documentation-only ones and refusing them would refuse a comment.
  it("ignores an unknown schema directive", t => {
    let message = translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity {
  id: ID!
  total: BigInt! @secretIndex
}
`,
    )
    t.expect(message).toEqual(accepted)
  })

  it("refuses an unknown @entity argument", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity(sharded: true) {
  id: ID!
}
`,
    )->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know the @entity argument "sharded".`,
      ~location="schema.graphql → type Token",
    )
  })

  // graph/src/schema/mod.rs: "skipDuplicates requires immutable: true".
  it("refuses skipDuplicates on a mutable type, as graph-node does", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity(skipDuplicates: true) {
  id: ID!
}
`,
    )->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't know skipDuplicates on the mutable type Token, which graph-node refuses as well (it requires immutable: true).`,
      ~location="schema.graphql → type Token",
    )
  })

  it("refuses an object type without @entity", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity {
  id: ID!
}

type Loose {
  id: ID!
}
`,
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't know the object type Loose without @entity.",
      ~location="schema.graphql → type Loose",
    )
  })

  it("refuses an unknown field type", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity {
  id: ID!
  weird: NotAType!
}
`,
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't know the type NotAType.",
      ~location="schema.graphql → Token.weird",
    )
  })
})

describe("subgraph translation: reporting", () => {
  // Subgraph mode ships under its own npm dist-tag, so `latest` would move a
  // subgraph project off it.
  it("points an unsupported feature at the subgraph release", t => {
    let message = translate(
      ~manifest=manifestWith(`      eventHandlers:
        - event: LOG_CALL(indexed bytes4,indexed address,bytes)
          topic0: "0x0000000000000000000000000000000000000000000000000000000000000001"
          handler: handleLogCall`),
      ~schema=baseSchema,
      ~extraAbi=`{"type":"event","name":"LOG_CALL","anonymous":true,"inputs":[{"name":"sig","type":"bytes4","indexed":true},{"name":"caller","type":"address","indexed":true},{"name":"data","type":"bytes","indexed":false}]}`,
    )
    t.expect(
      message,
    ).toEqual(`Envio Subgraph doesn't support the topic0 value 0x0000000000000000000000000000000000000000000000000000000000000001, which no bytes4 value encodes to yet.
  Found in data source "Token" → eventHandlers → "handleLogCall" → topic0.
First, make sure you're on the newest Envio Subgraph release — support may have landed:
  pnpm add -D envio@subgraph
If you're up to date and need this feature, please open an issue (existing
issues welcome a 👍 — demand drives prioritization):
  https://github.com/enviodev/hyperindex/issues`)
  })

  it("points an unknown thing at the subgraph release", t => {
    let message = translate(
      ~manifest=manifestWith(plainEventHandler)->String.replace(
        "dataSources:",
        "features:\n  - teleportation\ndataSources:",
      ),
      ~schema=baseSchema,
    )
    t.expect(message).toEqual(`Envio Subgraph doesn't know the feature "teleportation".
  Found in features[0].
This may be a feature newer than this envio version understands, or a typo.
First, make sure you're on the newest Envio Subgraph release:
  pnpm add -D envio@subgraph
If you're up to date and this is a real subgraph feature, please open an
issue so we can add it: https://github.com/enviodev/hyperindex/issues`)
  })

  it("reports every finding in one run", t => {
    let manifest =
      manifestWith(plainEventHandler)
      ->String.replace("dataSources:", "features:\n  - teleportation\ndataSources:")
      ->String.replace("kind: ethereum/contract", "kind: substreams")
    let message = translate(
      ~manifest,
      ~schema=`
type Token @entity {
  id: ID!
  weird: NotAType!
}
`,
    )
    t.expect((
      message->String.includes(`doesn't know the feature "teleportation"`),
      message->String.includes("can't index a substreams-powered subgraph"),
      message->String.includes("doesn't know the type NotAType"),
    )).toEqual((true, true, true))
  })
})

describe("subgraph translation: overloaded events", () => {
  // Envio reads a unique event's parameters out of the ABI, so the bare name is
  // enough; an overload isn't unique and has to be spelled out.
  let manifest = manifestWith(`      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
        - event: Transfer(indexed address,indexed address,uint256,bytes)
          handler: handleTransferData`)->String.replace(
    "      abis: []",
    `      abis:
        - name: Token
          file: ./abis/Token.json`,
  )

  let files = Dict.fromArray([
    (
      "./abis/Token.json",
      `[{"type":"event","name":"Transfer","anonymous":false,"inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"value","type":"uint256","indexed":false}]},{"type":"event","name":"Transfer","anonymous":false,"inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"id","type":"uint256","indexed":false},{"name":"data","type":"bytes","indexed":false}]}]`,
    ),
  ])

  it("registers both overloads as distinct events", t => {
    let {config} = InternalTestIndexer.fromSubgraph(~manifest, ~schema=baseSchema, ~files)
    let chain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
    let contract = chain.contracts->Array.getUnsafe(0)
    let names = contract.events->Array.map(event => event.name)
    let ids =
      contract.events->Array.map(
        event => (event->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)).sighash,
      )
    // Distinct topic0s: the two overloads resolved to different ABI entries.
    t.expect((names, ids->Array.getUnsafe(0) === ids->Array.getUnsafe(1))).toEqual((
      ["Transfer", "Transfer_1"],
      false,
    ))
  })
})
