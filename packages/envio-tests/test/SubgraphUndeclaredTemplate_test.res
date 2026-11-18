// daohaus' manifests are assembled per network by a script, and the one for
// a network without Uberhaus declares no `UberhausMinionTemplate` — while a
// mapping it still lists imports that class from generated/templates. graph
// codegen writes a class only for a declared template, so `graph build` fails
// on the import too; envio said only Node's "does not provide an export
// named". It names the template and what the manifest declares.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Summoned(address)
          handler: handleSummoned
      file: ./src/factory.ts
templates:
  - kind: ethereum/contract
    name: MinionTemplate
    network: mainnet
    source:
      abi: Factory
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Summoned(address)
          handler: handleSummoned
      file: ./src/factory.ts
`

let abi = `[{"type":"event","name":"Summoned","anonymous":false,"inputs":[{"name":"minion","type":"address","indexed":false}]}]`

let schema = `
type Probe @entity {
  id: ID!
}
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("./abis/Factory.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Factory.json", abi),
    (
      "src/factory.ts",
      `
import { UberhausMinionTemplate } from "../generated/templates";

export function handleSummoned(event: any): void {
  UberhausMinionTemplate.create(event.params.minion);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a mapping importing a template the manifest doesn't declare", () => {
  it("names the template", async (t) => {
    const indexer = createTestIndexer();

    await t
      .expect(indexer.process({ chains: { 1: { simulate: [] } } }))
      .rejects.toThrow(
        "Envio Subgraph failed to load the mapping ./src/factory.ts.\\n" +
          "  It imports UberhausMinionTemplate from generated/templates, and subgraph.yaml declares no " +
          "template UberhausMinionTemplate (it declares MinionTemplate). graph codegen writes a class only " +
          "for a template the manifest declares, so \`graph build\` fails on this import too: the manifest " +
          "was likely written for another network or deployment than the mappings.",
      );
  });
});
`,
)
