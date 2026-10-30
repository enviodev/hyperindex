// graph-cli before 0.93 ships CommonJS, as TypeScript compiles it: the command
// class is `exports.default`, which an ES import sees one level down. Most
// subgraphs in the wild pin one of those releases.
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
    (0, node_fs_1.writeFileSync)(
      (0, node_path_1.join)(outputDir, "schema.ts"),
      "export const generatedBy = \\"commonjs graph-cli\\";\\n",
    );
  }
}
exports.default = CodegenCommand;
`,
    ),
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { generatedBy } from "../generated/schema";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", generatedBy);
  store.set("Probe", "codegen", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a project pinned to a CommonJS graph-cli", () => {
  it("has its generated code built by that graph-cli", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "codegen", value: "commonjs graph-cli" }]);
  });
});
`,
)
