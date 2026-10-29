// sushiswap's legacy subgraphs import `const` and `pricing`, packages of their
// own yarn workspace (`packages/constants` is named `const`, `main: index.ts`).
// When the install fails (graph-cli 0.21's vanished gluegun fork), there is no
// node_modules to link them, and the package was looked for on the npm
// registry instead, where a package of that name is someone else's.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: PairCreated(uint256)
          handler: handlePairCreated
      file: ./src/factory.ts
`

let abi = `[{"type":"event","name":"PairCreated","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let schema = `
type Probe @entity {
  id: ID!
  value: String!
}
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("./abis/Factory.json", abi)]),
  ~projectDir="subgraphs/exchange",
  ~mappings=Dict.fromArray([
    ("package.json", `{"private": true, "workspaces": ["packages/*", "subgraphs/*"]}`),
    (
      "packages/constants/package.json",
      `{"name": "@envio-fixture/sushi-const", "main": "index.ts"}`,
    ),
    (
      "packages/constants/index.ts",
      `export const FACTORY_NAME: string = "sushiswap";\nexport { describe } from "./describe";\n`,
    ),
    (
      "packages/constants/describe.ts",
      `export function describe(name: string): string {\n  return name + " factory";\n}\n`,
    ),
    ("subgraphs/exchange/package.json", `{"name": "exchange"}`),
    ("subgraphs/exchange/subgraph.yaml", manifest),
    ("subgraphs/exchange/schema.graphql", schema),
    ("subgraphs/exchange/abis/Factory.json", abi),
    (
      "subgraphs/exchange/src/factory.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { FACTORY_NAME, describe } from "@envio-fixture/sushi-const";

export function handlePairCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", describe(FACTORY_NAME));
  store.set("Probe", "pair", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a mapping importing a package of its own workspace, with nothing installed", () => {
  it("loads the package from the workspace", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Factory", event: "PairCreated", params: { amount: 1n } }] } },
    });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "pair", value: "sushiswap factory" }]);
  });
});
`,
)
