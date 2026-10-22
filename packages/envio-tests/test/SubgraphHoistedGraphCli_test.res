// A subgraph in a yarn/npm workspace gets its graph-cli hoisted to the
// workspace root, where Node finds it by walking up from the package. envio
// only looked in the package's own node_modules, and said graph-cli wasn't
// installed (Polymarket, Venus, PancakeSwap, Multyr, Algebra, Autonolas, UMA).
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

let files = Dict.fromArray([
  (
    "abis/Pool.json",
    `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
  ),
])

let mapping = `
import { Entity, store } from "@graphprotocol/graph-ts";
import { invokedWith } from "../generated/schema";

export function handleCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", invokedWith);
  store.set("Probe", "codegen", probe);
}
`

let test = (~expected) =>
  `
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a graph-cli hoisted to the workspace root", () => {
  it("builds the generated code", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Created", params: { amount: 1n } }] } },
    });
    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "codegen", value: "${expected}" }]);
  });
});
`

let _ = InternalTestIndexer.fromSubgraph(
  ~projectDir="packages/pool",
  ~manifest,
  ~schema,
  ~files,
  ~mappings=Dict.fromArray([
    ("packages/pool/subgraph.yaml", manifest),
    ("packages/pool/src/pool.ts", mapping),
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
    writeFileSync(path.join(outputDir, "schema.ts"), 'export const invokedWith = "oclif";\\n');
  }
}
`,
    ),
  ]),
  ~test=test(~expected="oclif"),
)
