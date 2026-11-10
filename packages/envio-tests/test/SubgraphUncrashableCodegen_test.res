// Wildcat's codegen script is `graph codegen -u`: `--uncrashable` makes graph-cli
// also write `generated/UncrashableEntityHelpers.ts`, which every Wildcat mapping
// imports. envio's own run of graph codegen left the flag out, so the mappings
// failed on a missing module.
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
    ("package.json", `{"name":"uncrashable","scripts":{"codegen":"graph codegen -u"}}`),
    ("uncrashable-config.yaml", "entitySettings: {}\n"),
    (
      "node_modules/@graphprotocol/graph-cli/package.json",
      `{"name":"@graphprotocol/graph-cli","version":"0.80.1","main":"dist/index.js"}`,
    ),
    (
      "node_modules/@graphprotocol/graph-cli/dist/commands/codegen.js",
      `"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const node_fs_1 = require("node:fs");
const node_path_1 = require("node:path");
class CodegenCommand {
  static async run(argv) {
    const outputDir = argv[argv.indexOf("--output-dir") + 1];
    (0, node_fs_1.mkdirSync)(outputDir, { recursive: true });
    (0, node_fs_1.writeFileSync)((0, node_path_1.join)(outputDir, "schema.ts"), "export const schema = 1;\\n");
    if (argv.includes("--uncrashable")) {
      const config = argv[argv.indexOf("--uncrashable-config") + 1];
      (0, node_fs_1.writeFileSync)(
        (0, node_path_1.join)(outputDir, "UncrashableEntityHelpers.ts"),
        "export const helpers = \\"uncrashable " + (0, node_path_1.basename)(config) + "\\";\\n",
      );
    }
  }
}
exports.default = CodegenCommand;
`,
    ),
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { helpers } from "../generated/UncrashableEntityHelpers";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", helpers);
  store.set("Probe", "codegen", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a codegen script that runs graph codegen -u", () => {
  it("has the uncrashable helpers written", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "codegen", value: "uncrashable uncrashable-config.yaml" }]);
  });
});
`,
)
