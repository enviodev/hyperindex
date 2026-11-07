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

// sushiswap's `const` package is itself rendered per network: its own
// `prepare:mainnet` writes the `index.ts` its `main` names, and the root runs
// it through `yarn workspaces run prepare:mainnet`. Without it the error was
// Node's "Cannot find package"; it names what writes the file.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("./abis/Factory.json", abi)]),
  ~projectDir="subgraphs/exchange",
  ~mappings=Dict.fromArray([
    (
      "package.json",
      `{"private": true, "workspaces": ["packages/*", "subgraphs/*"], "scripts": {"prepare:mainnet": "yarn workspaces run prepare:mainnet"}}`,
    ),
    (
      "packages/constants/package.json",
      `{"name": "@envio-fixture/sushi-const", "main": "index.ts", "scripts": {"prepare:mainnet": "mustache ../../config/mainnet.json index.template.ts > index.ts"}}`,
    ),
    ("packages/constants/index.template.ts", `export const FACTORY_NAME: string = "{{name}}";\n`),
    ("subgraphs/exchange/package.json", `{"name": "exchange"}`),
    ("subgraphs/exchange/subgraph.yaml", manifest),
    ("subgraphs/exchange/schema.graphql", schema),
    ("subgraphs/exchange/abis/Factory.json", abi),
    (
      "subgraphs/exchange/src/factory.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { FACTORY_NAME } from "@envio-fixture/sushi-const";

export function handlePairCreated(event: any): void {
  let probe = new Entity();
  probe.setString("value", FACTORY_NAME);
  store.set("Probe", "pair", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a workspace package whose entry a script of its own writes", () => {
  it("names the script", async (t) => {
    const indexer = createTestIndexer();

    await t
      .expect(indexer.process({ chains: { 1: { simulate: [] } } }))
      .rejects.toThrow(
        'Envio Subgraph failed to load the mapping ./src/factory.ts.\\n' +
          '  @envio-fixture/sushi-const is a package of the project\\'s workspace (packages/constants), and the ' +
          'index.ts its package.json names doesn\\'t exist: its scripts prepare:mainnet write it. Run the one ' +
          'for your network, then start envio again.',
      );
  });
});
`,
)
