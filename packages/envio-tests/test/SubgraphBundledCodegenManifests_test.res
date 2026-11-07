// SubgraphCodegenScriptManifests_test.res without graph-cli: the bundled codegen
// writes every manifest the codegen script generates into the tree, as the
// script's `graph codegen` steps would, so a mapping importing a data source
// only the arbitrum manifest declares finds it.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Created(uint256)
          handler: handleCreated
      file: ./src/pool.ts
`

let schema = `
type Probe @entity {
  id: ID!
  value: String!
}
`

let abi = `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Pool.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    (
      "subgraph.arbitrum.yaml",
      manifest
      ->String.replace("network: mainnet", "network: arbitrum-one")
      ->String.replace("name: Pool\n", "name: ChildPool\n"),
    ),
    ("abis/Pool.json", abi),
    (
      "package.json",
      `{"name":"gauges-like","scripts":{"codegen":"graph codegen subgraph.yaml --output-dir src/types/ && graph codegen subgraph.arbitrum.yaml --output-dir src/types/"}}`,
    ),
    (
      "src/pool.ts",
      `
import { Created } from "./types/Pool/Pool";
import { Created as ChildCreated } from "./types/ChildPool/Pool";
import { Probe } from "./types/schema";

export function handleCreated(event: Created): void {
  let probe = new Probe("codegen");
  probe.value = event.params.amount.toString() + (ChildCreated != null ? "+child" : "");
  probe.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a codegen script naming two manifests, without graph-cli", () => {
  it("writes each into the tree", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 3n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "codegen", value: "3+child" }]);
  });
});
`,
)
