// graphprotocol/block-oracle's `"codegen": "yarn && graph codegen"` installs the
// dependencies before generating. envio runs a codegen script's other steps, so
// it ran that install too: a package manager with lifecycle scripts on, over a
// project it was only asked to index, and where `yarn` isn't there, the failed
// step threw graph codegen out for the bundled fallback. An install step is the
// developer's own business, done before envio starts; it is skipped.
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
      `{"name":"oracle-like","scripts":{"codegen":"yarn && graph codegen"}}`,
    ),
    // A `yarn` that fails, as one missing or refusing would.
    ("node_modules/.bin/yarn", "#!/bin/sh\necho installing > installed.txt\nexit 1\n"),
    (
      "node_modules/@graphprotocol/graph-cli/package.json",
      `{"name":"@graphprotocol/graph-cli","type":"module"}`,
    ),
    (
      "node_modules/@graphprotocol/graph-cli/dist/commands/codegen.js",
      `
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";

export default class CodegenCommand {
  static async run(argv) {
    const outputDir = argv[argv.indexOf("--output-dir") + 1];
    mkdirSync(outputDir, { recursive: true });
    const installed = existsSync(path.join(path.dirname(argv[0]), "installed.txt"));
    writeFileSync(
      path.join(outputDir, "schema.ts"),
      "export const fromGraph = \\"graph codegen" + (installed ? " after an install" : "") + "\\";\\n",
    );
  }
}
`,
    ),
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { fromGraph } from "../generated/schema";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", fromGraph);
  store.set("Probe", "codegen", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a codegen script that installs first", () => {
  it("runs graph codegen without the install", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "codegen", value: "graph codegen" }]);
  });
});
`,
)
