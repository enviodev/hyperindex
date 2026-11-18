// A field a new entity never sets is null in graph-node's store. The shim left
// it out of the row, and a nullable list column then failed the batch write
// (`Cannot read properties of undefined (reading 'length')`; Stability's
// VaultEntity history lists).
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
        - Resolver
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Named(string)
          handler: handleNamed
        - event: AddrChanged(string)
          handler: handleAddrChanged
      file: ./src/registry.ts
`,
  ~schema=`
type Resolver @entity {
  id: ID!
  name: String!
  addr: String!
  texts: [String!]
  contentHash: String
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"Named","anonymous":false,"inputs":[{"name":"value","type":"string","indexed":false}]},{"type":"event","name":"AddrChanged","anonymous":false,"inputs":[{"name":"value","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleNamed(event: any): void {
  let resolver = new Entity();
  resolver.setString("name", event.params.value);
  resolver.setString("addr", "none");
  resolver.set("texts", Value.fromStringArray(["avatar"]));
  resolver.setString("contentHash", "ipfs://x");
  store.set("Resolver", "r1", resolver);
}

export function handleAddrChanged(event: any): void {
  let resolver = new Entity();
  resolver.setString("name", "fresh");
  resolver.setString("addr", event.params.value);
  store.set("Resolver", "r2", resolver);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("saving a new entity", () => {
  it("stores the fields it never set as null", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Registry", event: "AddrChanged", params: { value: "0xabc" }, block: { number: 20 } },
          ],
        },
      },
    });
    t.expect(await indexer.Resolver.getAll()).toEqual([
      { id: "r2", name: "fresh", addr: "0xabc", texts: null, contentHash: null },
    ]);
  });
});
`,
)
