// graph codegen writes generated/<data source>/<ABI>.ts for each data source of
// the manifest it runs on, and nothing else. A mapping importing a path it never
// writes — revert's uni-v3-staker imports generated/UniV3Staker/ after renaming
// its data sources UniV3Staker1.0.0 and UniV3Staker1.0.2, which a stale local
// tree still had — fails `graph build` too (TS6054). envio reported only Node's
// "Cannot find module"; it now says what the manifest does declare.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: UniV3Staker1.0.0
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: UniV3Staker
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Stake
      abis:
        - name: UniV3Staker
          file: ./abis/UniV3Staker.json
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
  ~files=Dict.fromArray([("abis/UniV3Staker.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/UniV3Staker.json", abi),
    (
      "src/staker.ts",
      `
import { TokenStaked } from "../generated/UniV3Staker/UniV3Staker";
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
        "  Cannot find module '<root>/generated/UniV3Staker/UniV3Staker' imported from <root>/src/staker.ts\\n" +
        "graph codegen writes generated/<data source>/<ABI>.ts for each data source of the manifest, and the " +
        'manifest declares no data source named "UniV3Staker" (it has UniV3Staker1.0.0), so \`graph build\` ' +
        "fails on this import as well. A tree generated for an earlier manifest may still have the file.",
    );
  });
});
`,
)
