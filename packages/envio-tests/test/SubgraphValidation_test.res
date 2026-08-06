open Vitest

// One case per §7 row that translation can reach. Runtime-access refusals live
// in SubgraphRuntimeRefusal_test.res, where a mapping actually runs.
let translate = (~manifest, ~schema) =>
  try {
    InternalTestIndexer.fromSubgraph(~manifest, ~schema)->ignore
    "the translation to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }

let baseSchema = `
type Token @entity {
  id: ID!
  total: BigInt!
}
`

let manifestWith = mapping => `
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
  t.expect((
    message->String.includes(headline),
    message->String.includes(`Found in ${location}.`),
  ), ~message=message).toEqual((true, true))

describe("subgraph translation: unsupported features", () => {
  it("refuses call handlers", t => {
    translate(
      ~schema=baseSchema,
      ~manifest=manifestWith(`      callHandlers:
        - function: approve(address,uint256)
          handler: handleApprove`),
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support call handlers yet.",
      ~location=`data source "Token" → callHandlers → "handleApprove"`,
    )
  })

  it("refuses a call-filtered block handler", t => {
    translate(
      ~schema=baseSchema,
      ~manifest=manifestWith(`      blockHandlers:
        - handler: handleCall
          filter:
            kind: call`),
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support block handlers with `filter: call` yet.",
      ~location=`data source "Token" → blockHandlers → "handleCall"`,
    )
  })

  it("refuses grafting", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace(
        "dataSources:",
        "graft:\n  base: QmBase\n  block: 100\ndataSources:",
      )
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support grafting yet.",
      ~location="graft",
    )
  })

  it("refuses non-fatal errors", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace(
        "dataSources:",
        "features:\n  - nonFatalErrors\ndataSources:",
      )
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline=`Envio Subgraph doesn't support the "nonFatalErrors" feature yet.`,
      ~location="features[0]",
    )
  })

  it("refuses subgraph composition", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace("kind: ethereum/contract", "kind: subgraph")
    translate(~schema=baseSchema, ~manifest)->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support subgraph composition yet.",
      ~location=`data source "Token" → kind`,
    )
  })

  it("refuses a topic filter", t => {
    translate(
      ~schema=baseSchema,
      ~manifest=manifestWith(`      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
          topic1:
            - "0x0000000000000000000000000000000000000000000000000000000000000001"`),
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support topic filters on dynamically-typed indexed parameters yet.",
      ~location=`data source "Token" → eventHandlers → "handleTransfer" → topic filters`,
    )
  })

  it("refuses GraphQL interfaces", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
interface Named {
  id: ID!
}

type Token implements Named @entity {
  id: ID!
}
`,
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't support GraphQL interfaces yet.",
      ~location="schema.graphql → interface Named",
    )
  })

  it("refuses timeseries entities", t => {
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
      ~headline="Envio Subgraph doesn't support timeseries and aggregations yet.",
      ~location="schema.graphql → type Token @entity(timeseries: true)",
    )
  })
})

describe("subgraph translation: unknown things", () => {
  it("refuses an unknown manifest field", t => {
    let manifest =
      manifestWith(plainEventHandler)->String.replace("dataSources:", "speVersion: 0.0.5\ndataSources:")
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

  it("refuses an unknown schema directive", t => {
    translate(
      ~manifest=manifestWith(plainEventHandler),
      ~schema=`
type Token @entity {
  id: ID!
  total: BigInt! @secretIndex
}
`,
    )->expectFindingHelper(
      t,
      ~headline="Envio Subgraph doesn't know the schema directive @secretIndex.",
      ~location="schema.graphql → Token.total",
    )
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
  it("reports every finding in one run", t => {
    let manifest =
      manifestWith(`      callHandlers:
        - function: approve(address,uint256)
          handler: handleApprove`)->String.replace(
        "dataSources:",
        "features:\n  - nonFatalErrors\ndataSources:",
      )
    let message = translate(
      ~manifest,
      ~schema=`
interface Named {
  id: ID!
}

type Token @entity {
  id: ID!
}
`,
    )
    t.expect(
      (
        message->String.includes(`doesn't support the "nonFatalErrors" feature`),
        message->String.includes("doesn't support call handlers"),
        message->String.includes("doesn't support GraphQL interfaces"),
      ),
    ).toEqual((true, true, true))
  })
})

describe("subgraph translation: overloaded events", () => {
  // Envio reads a unique event's parameters out of the ABI, so the bare name is
  // enough; an overload isn't unique and has to be spelled out.
  let manifest = manifestWith(`      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
        - event: Transfer(indexed address,indexed address,uint256,bytes)
          handler: handleTransferData`)->String.replace("      abis: []", `      abis:
        - name: Token
          file: ./abis/Token.json`)

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
    let ids = contract.events->Array.map(event => event.id)
    // Distinct topic0s: the two overloads resolved to different ABI entries.
    t.expect((names, ids->Array.getUnsafe(0) === ids->Array.getUnsafe(1))).toEqual((
      ["Transfer", "Transfer_1"],
      false,
    ))
  })
})
