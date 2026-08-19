// A field the schema declares but nothing has set. graph-node's store returns
// every column, so the mapping reads `null`; envio's returns what was written,
// so the field is simply absent — and ENS's `domain.resolver == null` is a
// null check on exactly that.
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
        - Domain
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Domain @entity {
  id: ID!
  owner: String!
  resolver: String
  parent: Domain
  seen: Boolean!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, store, Value } from "@graphprotocol/graph-ts";

export function handleNewOwner(event: any): void {
  let created = new Entity();
  created.setString("owner", "0xowner");
  created.setBoolean("seen", false);
  store.set("Domain", "d1", created);

  // Loaded back, the entity carries only what was written — the way ENS reads
  // a domain it created earlier in the same run.
  let domain = store.get("Domain", "d1")!;
  let unset = domain.resolver == null && domain.parent == null;

  let out = new Entity();
  out.setString("owner", "0xowner");
  out.setBoolean("seen", unset);
  // A relation is an entity id on both sides, and envio names its column
  // parent_id.
  out.setString("parent", "d1");
  store.set("Domain", "d2", out);

  let reloaded = store.get("Domain", "d2")!;
  let roundTripped = new Entity();
  roundTripped.setString("owner", reloaded.parent);
  roundTripped.setBoolean("seen", true);
  store.set("Domain", "d3", roundTripped);
}
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a declared field nothing has set", () => {
  it("reads as null instead of refusing", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 1n } }] },
      },
    });

    t.expect([
      await indexer.Domain.getOrThrow("d2"),
      await indexer.Domain.getOrThrow("d3"),
    ]).toEqual([
      { id: "d2", owner: "0xowner", resolver: undefined, parent_id: "d1", seen: true },
      { id: "d3", owner: "d1", resolver: undefined, parent_id: undefined, seen: true },
    ]);
  });

  it("still refuses a member the schema doesn't declare", async () => {
    await expect(
      createTestIndexer().process({
        chains: {
          1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 2n } }] },
        },
      }),
    ).resolves.toBeDefined();
  });
});
`,
)
