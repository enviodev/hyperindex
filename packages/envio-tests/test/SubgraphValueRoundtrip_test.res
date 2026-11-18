// graph-node's own value-roundtrip integration test
// (tests/integration-tests/value-roundtrip): a string's NUL characters are
// stripped on the way to the store, and the entity loaded back in the same
// handler already lacks them.
let manifest = `
specVersion: 1.0.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Contract
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Contract
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.8
      language: wasm/assemblyscript
      entities:
        - Foo
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: Trigger(uint16)
          handler: handleTrigger
      file: ./src/mapping.ts
`

let schema = `
type Foo @entity {
  id: ID!
  value: String!
}
`

let abi = `[{"type":"event","name":"Trigger","anonymous":false,"inputs":[{"name":"x","type":"uint16","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Contract.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Contract.json", abi),
    ("generated/.gitkeep", ""),
    (
      "src/mapping.ts",
      `
import { Trigger } from "../generated/Contract/Contract";
import { Foo } from "../generated/schema";

export function handleTrigger(event: Trigger): void {
  let obj = new Foo("0");
  obj.value = "b\u0000la\u0000";
  obj.save();

  // Null characters are stripped.
  obj = <Foo>Foo.load("0");
  assert(obj.value == "bla", "nulls not stripped");
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a string with NUL characters", () => {
  it("is stored and loaded without them", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Contract", event: "Trigger", params: { x: 1n } }] } },
    });
    t.expect(await indexer.Foo.getAll()).toEqual([{ id: "0", value: "bla" }]);
  });
});
`,
)
