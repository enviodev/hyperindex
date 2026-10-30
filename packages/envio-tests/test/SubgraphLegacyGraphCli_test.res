// A graph-cli from before oclif — GMX's and PancakeSwap's 0.21 — has no
// `dist/commands/` to run in-process, only its gluegun bin, so envio runs
// that bin. Hoisted to the workspace root here, as those monorepos have it.
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

describe("a pre-oclif graph-cli hoisted to the workspace root", () => {
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
  ~projectDir="subgraphs/pool",
  ~manifest,
  ~schema,
  ~files,
  ~mappings=Dict.fromArray([
    ("subgraphs/pool/subgraph.yaml", manifest),
    ("subgraphs/pool/src/pool.ts", mapping),
    (
      "node_modules/@graphprotocol/graph-cli/package.json",
      `{"name":"@graphprotocol/graph-cli","version":"0.21.3","bin":{"graph":"bin/graph"}}`,
    ),
    (
      "node_modules/@graphprotocol/graph-cli/bin/graph",
      `#!/usr/bin/env node
const { mkdirSync, writeFileSync } = require("node:fs");
const path = require("node:path");
const argv = process.argv.slice(2);
const outputDir = argv[argv.indexOf("--output-dir") + 1];
mkdirSync(outputDir, { recursive: true });
writeFileSync(
  path.join(outputDir, "schema.ts"),
  "export const invokedWith = " + JSON.stringify("gluegun " + argv[0] + " " + path.basename(argv[1])) + ";\\n",
);
`,
    ),
  ]),
  ~test=test(~expected="gluegun codegen subgraph.yaml"),
)
