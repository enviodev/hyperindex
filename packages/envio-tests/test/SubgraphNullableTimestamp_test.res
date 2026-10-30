// A nullable `Timestamp` field set to null saves and loads as null, as on
// graph-node, rather than failing the store's microsecond conversion.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pair
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Touched(uint256)
          handler: handleTouched
      file: ./src/registry.ts
`,
  ~schema=`
type Pair @entity {
  id: ID!
  closedAt: Timestamp
  touches: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"Touched","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, store, Value } from "@graphprotocol/graph-ts";

export function handleTouched(event: any): void {
  let pair = store.get("Pair", "p1");
  if (pair == null) {
    pair = new Entity();
    pair.setI32("touches", 0);
  }
  pair.set("closedAt", Value.fromNull());
  pair.setI32("touches", pair.getI32("touches") + 1);
  store.set("Pair", "p1", pair);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const touched = (nonce: bigint) => ({ contract: "Registry", event: "Touched", params: { nonce } });

describe("a nullable Timestamp field", () => {
  it("saves and loads a null", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [touched(1n)] } } });
    await indexer.process({ chains: { 1: { simulate: [touched(2n)] } } });

    t.expect(await indexer.Pair.getAll()).toEqual([{ id: "p1", closedAt: null, touches: 2 }]);
  });
});
`,
)
