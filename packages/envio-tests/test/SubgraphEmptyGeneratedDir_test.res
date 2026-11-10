// Envio Cloud drops a project's generated/ and recreates it empty before the
// build, and envio skipped codegen whenever the directory existed: the pod
// crash-looped on its mappings' ../generated/schema imports. A generated
// directory missing a file the mappings import is now built like a missing one.
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

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema=`
type Probe @entity {
  id: ID!
  value: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    // What the platform leaves: the directory, and nothing the mappings import.
    ("src/types/.gitkeep", ""),
    (
      "node_modules/@graphprotocol/graph-cli/package.json",
      `{"name":"@graphprotocol/graph-cli","type":"module"}`,
    ),
    (
      "node_modules/@graphprotocol/graph-cli/dist/commands/codegen.js",
      `
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

export default class CodegenCommand {
  static async run(argv) {
    const [manifest] = argv;
    const outputDir = argv[argv.indexOf("--output-dir") + 1];
    const root = path.dirname(manifest);
    const invokedWith = argv.map((arg) => (path.isAbsolute(arg) ? path.relative(root, arg) : arg));
    mkdirSync(outputDir, { recursive: true });
    writeFileSync(
      path.join(outputDir, "schema.ts"),
      "export const invokedWith = " + JSON.stringify(invokedWith.join(" ")) + ";\\n",
    );
  }
}
`,
    ),
    // Imports its generated code from where \`graph codegen -o src/types\` put it.
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { invokedWith } from "./types/schema";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("id", "codegen");
  probe.setString("value", invokedWith);
  store.set("Probe", "codegen", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an empty generated directory", () => {
  it("is built like a missing one", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([
      { id: "codegen", value: "subgraph.yaml --output-dir src/types --skip-migrations" },
    ]);
  });
});
`,
)
