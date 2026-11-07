// graph codegen writes generated/<data source>/<ABI>.ts for each data source of
// the manifest it runs on, and nothing else. A mapping importing a path it never
// writes, from an ABI no manifest names and not under the data source's own name,
// fails `graph build` too (TS6054), and envio has nothing to write it from when
// no generated module has the names it imports (here the binding `Controller`).
// envio reported only Node's "Cannot find module"; it now says what the manifest
// does declare.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: NNSController
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: IController
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Stake
      abis:
        - name: IController
          file: ./abis/IController.json
      eventHandlers:
        - event: TokenStaked(uint256)
          handler: handleTokenStaked
      file: ./src/staker.ts
`

let schema = `
type Stake @entity {
  id: ID!
}
`

let abi = `[{"type":"event","name":"TokenStaked","anonymous":false,"inputs":[{"name":"tokenId","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/IController.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/IController.json", abi),
    (
      "src/staker.ts",
      `
import { Controller, TokenStaked } from "../generated/NNSController/Controller";
import { Stake } from "../generated/schema";

export function handleTokenStaked(event: TokenStaked): void {
  new Stake(event.params.tokenId.toString()).save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a mapping importing generated code graph codegen doesn't write", () => {
  it("names what the manifest declares", async (t) => {
    const indexer = createTestIndexer();
    const message = await indexer
      .process({ chains: { 1: { simulate: [] } } })
      .then(() => "processed", (error) => String(error.message).replace(/\\/[^\\s']*envio-subgraph-[^/\\s']+/g, "<root>"));

    t.expect(message).toBe(
      "Envio Subgraph failed to load the mapping ./src/staker.ts.\\n" +
        "  Cannot find module '<root>/generated/NNSController/Controller' imported from <root>/src/staker.ts\\n" +
        "graph codegen writes generated/<data source>/<ABI>.ts for each data source of the manifest, and " +
        'its data source "NNSController" has no ABI named "Controller" (it has IController), so \`graph build\` ' +
        "fails on this import as well. A tree generated for an earlier manifest may still have the file.",
    );
  });
});
`,
)
