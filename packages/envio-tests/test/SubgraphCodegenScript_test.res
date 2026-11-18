// A project's `codegen` script is how its generated code is built, and some do
// more than `graph codegen`: Lido's writes `generated/parserData.ts` with a
// step of its own after it. Every step runs, in order, so the mappings find
// what the developer's own `pnpm codegen` would have left.
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
      `{"name":"lido-like","scripts":{"codegen":"graph codegen && node genParserData.js"}}`,
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
    // The project's own step, which reads what graph codegen wrote.
    (
      "genParserData.js",
      `
const { readFileSync, writeFileSync } = require("node:fs");
const schema = readFileSync("generated/schema.ts", "utf8");
writeFileSync(
  "generated/parserData.ts",
  "export const parserData = \\"after " + (schema.includes("graph codegen") ? "graph codegen" : "nothing") + "\\";\\n",
);
`,
    ),
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { fromGraph } from "../generated/schema";
import { parserData } from "../generated/parserData";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", fromGraph + " / " + parserData);
  store.set("Probe", "codegen", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a codegen script with steps of its own", () => {
  it("runs them after graph codegen", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([
      { id: "codegen", value: "graph codegen / after graph codegen" },
    ]);
  });
});
`,
)
