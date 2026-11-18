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
        - event: Deposited(uint256)
          handler: handleDeposited
      file: ./src/pool.ts
`

let abi = `[{"type":"event","name":"Deposited","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let schema = `
type Probe @entity {
  id: ID!
  value: String!
}
`

// Goldfinch's mappings import src/address-manifest.ts, which its `"prebuild":
// "ts-node ./scripts/update-address-manifest.ts"` writes from the protocol's
// deployments before `graph codegen && graph build`. The error was Node's bare
// "Cannot find module"; it names the script that writes the file.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("./abis/Pool.json", abi)]),
  ~mappings=Dict.fromArray([
    (
      "package.json",
      `{"name": "goldfinch-like", "scripts": {"prebuild": "ts-node ./scripts/update-address-manifest.ts", "build": "yarn prebuild && graph codegen && graph build", "codegen": "graph codegen"}}`,
    ),
    ("scripts/update-address-manifest.ts", `// writes src/address-manifest.ts\n`),
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Pool.json", abi),
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { POOL_NAME } from "./address-manifest";

export function handleDeposited(event: any): void {
  let probe = new Entity();
  probe.setString("value", POOL_NAME);
  store.set("Probe", "pool", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a mapping importing a file a package.json script writes", () => {
  it("names the script", async (t) => {
    const indexer = createTestIndexer();

    await t
      .expect(indexer.process({ chains: { 1: { simulate: [] } } }))
      .rejects.toThrow(
        'src/address-manifest.ts, which the mapping imports, isn\\'t in the repo: the package.json script ' +
          '"prebuild" writes it (ts-node ./scripts/update-address-manifest.ts), and \`graph build\` fails on this ' +
          'import too until it has run. Run it, then start envio again.',
      );
  });
});
`,
)
