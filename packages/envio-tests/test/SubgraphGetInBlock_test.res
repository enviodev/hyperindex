// graph-node's store.get_in_block (GetScope::InBlock in
// graph/src/components/store/entity_cache.rs) answers only what this block has
// stored so far, an earlier handler of the block included; store.get answers
// from any block.
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
        - Item
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: Trigger(uint16)
          handler: handleTrigger
      file: ./src/mapping.ts
`

let schema = `
type Item @entity {
  id: ID!
}

type Seen @entity {
  id: ID!
  inBlock: Boolean!
  anyBlock: Boolean!
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
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleTrigger(event: Trigger): void {
  if (event.params.x == 0) {
    store.set("Item", "a", new Entity());
    return;
  }
  let seen = new Entity();
  seen.setBoolean("inBlock", store.get_in_block("Item", "a") != null);
  seen.setBoolean("anyBlock", store.get("Item", "a") != null);
  store.set("Seen", event.block.number.toString(), seen);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("store.get_in_block", () => {
  it("sees this block's saves only", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Contract", event: "Trigger", params: { x: 0n }, block: { number: 5 } },
            { contract: "Contract", event: "Trigger", params: { x: 1n }, block: { number: 5 } },
            { contract: "Contract", event: "Trigger", params: { x: 1n }, block: { number: 6 } },
          ],
        },
      },
    });
    t.expect((await indexer.Seen.getAll()).sort((a: any, b: any) => (a.id < b.id ? -1 : 1))).toEqual([
      { id: "5", inBlock: true, anyBlock: true },
      { id: "6", inBlock: false, anyBlock: true },
    ]);
  });
});
`,
)
