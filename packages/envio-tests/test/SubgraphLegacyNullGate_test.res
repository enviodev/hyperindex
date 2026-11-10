// From apiVersion 0.0.5 graph-node traps on a null receiver, so the tolerance
// SubgraphLegacyNullReceiver_test.res gives 0.0.4 mappings must not reach them.
let manifest = apiVersion =>
  `
specVersion: 0.0.2
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
      apiVersion: ${apiVersion}
      language: wasm/assemblyscript
      entities:
        - Order
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`

let schema = `
type Order @entity {
  id: ID!
  premium: BigInt!
}
`

let files = Dict.fromArray([
  (
    "abis/Registry.json",
    `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
  ),
])

let mappings = Dict.fromArray([
  (
    "src/registry.ts",
    `
import { BigInt, Entity, store, Value } from "@graphprotocol/graph-ts";

function nothing(): BigInt | null {
  return null;
}

export function handleNewOwner(event: any): void {
  let order = new Entity();
  order.set("id", Value.fromString("o1"));
  order.set("premium", Value.fromBigInt(nothing()!.plus(BigInt.fromI32(1))));
  store.set("Order", "o1", order);
}
`,
  ),
])

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=manifest("0.0.7"),
  ~schema,
  ~files,
  ~mappings,
  ~test=`
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

describe("a null receiver under apiVersion 0.0.7", () => {
  it("still fails", async () => {
    await expect(
      createTestIndexer().process({
        chains: {
          1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 1n } }] },
        },
      }),
    ).rejects.toThrow();
  });
});
`,
)
