// TOKERIZE's mapping imports the entity `BondBroken` from generated/schema, and
// its schema declares `BondBrokenEvent`: graph codegen writes no such class, and
// `graph build` fails on the import. envio reported Node's bare "does not
// provide an export named"; it now says the generated file is graph codegen's
// output for this project and lists what it does export by that kind of name.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Governance
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Governance
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - BondBrokenEvent
      abis:
        - name: Governance
          file: ./abis/Governance.json
      eventHandlers:
        - event: BondBroken(uint256)
          handler: handleBondBroken
      file: ./src/mapping.ts
`

let schema = `
type BondBrokenEvent @entity(immutable: true) {
  id: ID!
}

type Bond @entity {
  id: ID!
}
`

let abi = `[{"type":"event","name":"BondBroken","anonymous":false,"inputs":[{"name":"bondId","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Governance.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Governance.json", abi),
    (
      "src/mapping.ts",
      `
import { BondBroken as BondBrokenEvent } from "../generated/Governance/Governance";
import { BondBroken } from "../generated/schema";

export function handleBondBroken(event: BondBrokenEvent): void {
  new BondBroken(event.params.bondId.toString()).save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a mapping importing a name graph codegen doesn't generate", () => {
  it("says what the generated file exports", async (t) => {
    const indexer = createTestIndexer();
    const message = await indexer
      .process({ chains: { 1: { simulate: [] } } })
      .then(() => "processed", (error) => String(error.message));

    t.expect(message).toBe(
      "Envio Subgraph failed to load the mapping ./src/mapping.ts.\\n" +
        "  The requested module '../generated/schema' does not provide an export named 'BondBroken'\\n" +
        "generated/schema.ts is graph codegen's output for this project and has no BondBroken (it exports Bond, " +
        "BondBrokenEvent), so \`graph build\` fails on this import as well.",
    );
  });
});
`,
)
