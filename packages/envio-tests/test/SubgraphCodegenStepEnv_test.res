// The codegen script's own steps are the repo's code, as the one script that
// writes a manifest is (§6d): envio's settings — its HyperSync token, the
// database password — stay out of their environment. Lido's step after `graph
// codegen` saw every ENVIO_* variable envio was started with.
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
    (
      "package.json",
      `{"name":"lido-like","scripts":{"codegen":"graph codegen && node genEnv.js"}}`,
    ),
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
    const outputDir = argv[argv.indexOf("--output-dir") + 1];
    mkdirSync(outputDir, { recursive: true });
    writeFileSync(path.join(outputDir, "schema.ts"), "export const fromGraph = \\"graph codegen\\";\\n");
  }
}
`,
    ),
    // Counts the names only.
    (
      "genEnv.js",
      `
const { writeFileSync } = require("node:fs");
const names = Object.keys(process.env).filter((name) => name.startsWith("ENVIO_"));
writeFileSync("generated/env.ts", "export const envioVariables = " + names.length + ";\\n");
`,
    ),
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { envioVariables } from "../generated/env";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", "envio variables: " + envioVariables.toString());
  store.set("Probe", "codegen", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a codegen script step", () => {
  it("runs without envio's own settings in its environment", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "codegen", value: "envio variables: 0" }]);
  });
});
`,
)
