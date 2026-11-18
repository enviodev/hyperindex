// The register pass reruns, at fetch time, only handlers whose code can reach a
// create, against a store holding what earlier passes saved. Heavy Helms
// creates a template only when the SkinCollection that `handleSkinRegistered`
// saved exists — and that handler creates nothing, so no pass ever saved it:
// the create was skipped and the template's events lost. A handler that
// touches an entity type a create depends on gets a register pass too.
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
      abi: Events
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Collection
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: Registered(uint256,address)
          handler: handleRegistered
        - event: Verified(uint256)
          handler: handleVerified
      file: ./src/registry.ts
templates:
  - kind: ethereum/contract
    name: Nft
    network: mainnet
    source:
      abi: Events
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Token
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: Minted(uint256)
          handler: handleMinted
      file: ./src/nft.ts
`,
  ~schema=`
type Collection @entity {
  id: ID!
  nft: String!
}
type Token @entity {
  id: ID!
  nft: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Events.json",
      `[{"type":"event","name":"Registered","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false},{"name":"nft","type":"address","indexed":false}]},{"type":"event","name":"Verified","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false}]},{"type":"event","name":"Minted","anonymous":false,"inputs":[{"name":"tokenId","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { DataSourceTemplate, Entity, store } from "@graphprotocol/graph-ts";

export function handleRegistered(event: any): void {
  let collection = new Entity();
  collection.setString("nft", event.params.nft.toHexString());
  store.set("Collection", event.params.id.toString(), collection);
}

export function handleVerified(event: any): void {
  let collection = store.get("Collection", event.params.id.toString());
  if (collection != null) {
    DataSourceTemplate.create("Nft", [collection.getString("nft")]);
  }
}
`,
    ),
    (
      "src/nft.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleMinted(event: any): void {
  let token = new Entity();
  token.setString("nft", event.address.toHexString());
  store.set("Token", event.params.tokenId.toString(), token);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const registry = "0x1111111111111111111111111111111111111111";
const nft = "0x2222222222222222222222222222222222222222";

describe("the register pass", () => {
  it("sees what a create-free handler saved that a create depends on", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Registry", event: "Registered", params: { id: 1n, nft }, srcAddress: registry, block: { number: 5 } },
            { contract: "Registry", event: "Verified", params: { id: 1n }, srcAddress: registry, block: { number: 10 } },
            { contract: "Nft", event: "Minted", params: { tokenId: 7n }, srcAddress: nft, block: { number: 20 } },
          ],
        },
      },
    });

    t.expect(await indexer.Token.getAll()).toEqual([{ id: "7", nft }]);
  });
});
`,
)
