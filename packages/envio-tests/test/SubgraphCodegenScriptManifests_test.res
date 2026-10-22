// balancer/gauges-subgraph generates one tree from two manifests:
// `graph codegen subgraph.yaml --output-dir src/types/ && graph codegen
// subgraph.arbitrum.yaml --output-dir src/types/`, and its mappings import data
// sources only the arbitrum manifest declares. envio ran each step on its own
// manifest, dropping the one the step names, so the arbitrum half was never
// written.
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

let abi = `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema=`
type Probe @entity {
  id: ID!
  value: String!
}
`,
  ~files=Dict.fromArray([("abis/Pool.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("subgraph.arbitrum.yaml", manifest->String.replace("network: mainnet", "network: arbitrum-one")),
    ("abis/Pool.json", abi),
    (
      "package.json",
      `{"name":"gauges-like","scripts":{"codegen":"graph codegen subgraph.yaml --output-dir src/types/ && graph codegen subgraph.arbitrum.yaml --output-dir src/types/"}}`,
    ),
    (
      "node_modules/@graphprotocol/graph-cli/package.json",
      `{"name":"@graphprotocol/graph-cli","type":"module"}`,
    ),
    // Writes one file per manifest it is run on, plus schema.ts.
    (
      "node_modules/@graphprotocol/graph-cli/dist/commands/codegen.js",
      `
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

export default class CodegenCommand {
  static async run(argv) {
    const outputDir = argv[argv.indexOf("--output-dir") + 1];
    const name = path.basename(argv[0]).replace(/\\W/g, "_");
    mkdirSync(outputDir, { recursive: true });
    writeFileSync(path.join(outputDir, "schema.ts"), "export const schema = \\"schema\\";\\n");
    writeFileSync(path.join(outputDir, name + ".ts"), "export const manifest = \\"" + name + "\\";\\n");
  }
}
`,
    ),
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { schema } from "./types/schema";
import { manifest as main } from "./types/subgraph_yaml";
import { manifest as arbitrum } from "./types/subgraph_arbitrum_yaml";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("id", "codegen");
  probe.setString("value", schema + "+" + main + "+" + arbitrum);
  store.set("Probe", "codegen", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a codegen script naming two manifests", () => {
  it("generates each into the tree", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([
      { id: "codegen", value: "schema+subgraph_yaml+subgraph_arbitrum_yaml" },
    ]);
  });
});
`,
)
