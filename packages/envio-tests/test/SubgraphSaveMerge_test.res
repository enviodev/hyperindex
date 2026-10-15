// graph-node's `save()` of an entity that already exists merges onto the stored
// one (entity_cache.rs: EntityCache::set is an Update, merged with
// merge_remove_null_fields): a field the new instance doesn't set keeps its
// stored value, an explicit null removes it. The shim replaced the row, so ENS's
// handleAddrChanged, which saves a fresh `new Resolver(id)`, wiped the fields
// other handlers had set.
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
  // A fresh instance, as ENS writes it: only what this event changes.
  let resolver = new Entity();
  resolver.setString("addr", event.params.value);
  resolver.set("contentHash", Value.fromNull());
  store.set("Resolver", "r1", resolver);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("saving an entity that already exists", () => {
  it("merges onto the stored one, as graph-node does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Registry", event: "Named", params: { value: "vitalik.eth" }, block: { number: 10 } },
            { contract: "Registry", event: "AddrChanged", params: { value: "0xabc" }, block: { number: 20 } },
          ],
        },
      },
    });
    t.expect(await indexer.Resolver.getAll()).toEqual([
      { id: "r1", name: "vitalik.eth", addr: "0xabc", texts: ["avatar"], contentHash: null },
    ]);
  });
});
`,
)
