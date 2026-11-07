// graph-cli before 0.22 wrote a nullable field's setter as
// `if (value === null) unset else set` (src/codegen/schema.js); 0.22 changed it
// to `if (!value)`, and AssemblyScript's `!` on a string is true for "" too, so
// newer code clears a field set to "" where older code stored "". A project on
// graph-cli 0.21 (Uniswap v3-era subgraphs, whose install no longer works) gets
// its tree from the bundled codegen, which wrote the newer form: a token whose
// symbol() returns "" lost it.
let manifest = `
specVersion: 0.0.2
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
      apiVersion: 0.0.4
      language: wasm/assemblyscript
      entities:
        - Token
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Listed(uint256)
          handler: handleListed
      file: ./src/factory.ts
`

let schema = `
type Token @entity {
  id: ID!
  symbol: String
}
`

let abi = `[{"type":"event","name":"Listed","anonymous":false,"inputs":[{"name":"token","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Factory.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Factory.json", abi),
    (
      "package.json",
      `{"name":"v3-era","devDependencies":{"@graphprotocol/graph-cli":"0.21.1","@graphprotocol/graph-ts":"0.20.0"}}`,
    ),
    (
      "src/factory.ts",
      `
import { Listed } from "../generated/Factory/Factory";
import { Token } from "../generated/schema";

export function handleListed(event: Listed): void {
  let token = new Token(event.params.token.toString());
  token.symbol = "";
  token.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a nullable field set to an empty string under graph-cli 0.21", () => {
  it("is stored, as that release's setter stored it", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Factory", event: "Listed", params: { token: 1n } }] } },
    });

    t.expect(await indexer.Token.getAll()).toEqual([{ id: "1", symbol: "" }]);
  });
});
`,
)
