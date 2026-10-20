// graph-node validates a saved entity, merged onto the stored one, against the
// schema: a non-null field neither set nor stored fails the handler with
// "missing value for non-nullable field" (EntityCache::set, Entity::validate).
// Opolis' ensureOpolisPayToken saves an OpolisPayToken without its `createdAt:
// BigInt!`; envio accepted the save and the batch write failed later on a
// null it couldn't serialize.
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
        - Token
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Token @entity {
  id: ID!
  symbol: String!
  note: String
  createdAt: BigInt!
  holders: [Holder!]! @derivedFrom(field: "token")
}

type Holder @entity {
  id: ID!
  token: Token!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"kind","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

export function handleNewOwner(event: any): void {
  let kind = event.params.kind.toI32();
  let token = new Entity();
  token.setString("symbol", "ETH");
  if (kind != 1) token.setBigInt("createdAt", BigInt.fromI32(5));
  store.set("Token", "t" + kind.toString(), token);

  // A later save of only some fields merges onto the stored entity.
  if (kind == 2) {
    let update = new Entity();
    update.setString("note", "updated");
    store.set("Token", "t2", update);
  }
}
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

const probe = (kind: bigint) => ({
  chains: { 1: { simulate: [{ contract: "Registry" as const, event: "NewOwner" as const, params: { kind } }] } },
});

describe("a saved entity", () => {
  it("merges a partial save onto what is stored", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process(probe(2n));
    t.expect(await indexer.Token.getOrThrow("t2")).toEqual({ id: "t2", symbol: "ETH", note: "updated", createdAt: 5n });
  });

  it("fails the handler when a non-null field is missing, as graph-node does", async () => {
    await expect(createTestIndexer().process(probe(1n))).rejects.toThrow(
      "Entity Token[t1]: missing value for non-nullable field \`createdAt\`",
    );
  });
});
`,
)
