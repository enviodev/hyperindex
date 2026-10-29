open Vitest

// Hats: `Hat.wearers: [Wearer!]!` is stored as one array of ids, and
// `Wearer.currentHats` derives from it. A btree index over that column fails a
// write as soon as one hat has a few hundred wearers ("index row size 6944
// exceeds btree version 4 maximum 2704"); graph-node indexes a list attribute
// with GIN.
let {InternalTestIndexer.config: config} = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Hats
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Hats
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Hat
      abis:
        - name: Hats
          file: ./abis/Hats.json
      eventHandlers:
        - event: HatCreated(uint256)
          handler: handleHatCreated
      file: ./src/hats.ts
`,
  ~schema=`
type Hat @entity {
  id: ID!
  wearers: [Wearer!]!
}

type Wearer @entity {
  id: ID!
  currentHats: [Hat!]! @derivedFrom(field: "wearers")
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Hats.json",
      `[{"type":"event","name":"HatCreated","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([("src/hats.ts", `export function handleHatCreated(): void {}`)]),
)

describe("A derived lookup over a stored entity list", () => {
  it("is indexed with GIN, as graph-node indexes list attributes", t => {
    t.expect(
      Storage.getSchemaIndexes(~entities=config.userEntities)->Array.map(IndexDefinition.describe),
    ).toEqual(["Hat(wearers) using gin"])
  })
})
