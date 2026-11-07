// `entity.field = event.params.get("misspelt")!` (GMX's "callbakGasLimit"):
// the lookup is null, graph-node's `!` lets it through, and the entity is
// saved with a BigInt that reads as zero. envio used to throw
// "Cannot convert null to a BigInt" out of the save.
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
        - Order
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Order @entity {
  id: ID!
  gasLimit: BigInt!
  fee: BigInt!
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
import { BigInt, Entity, store, Value } from "@graphprotocol/graph-ts";

function lookup(key: string): BigInt | null {
  return null;
}

export function handleNewOwner(event: any): void {
  let order = new Entity();
  order.set("gasLimit", Value.fromBigInt(lookup("callbakGasLimit")!));
  order.set("fee", Value.fromBigInt(BigInt.fromI32(7)));
  store.set("Order", "o1", order);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a null BigInt behind a non-null assertion", () => {
  it("is saved as zero", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 1n } }] },
      },
    });

    t.expect(await indexer.Order.getOrThrow("o1")).toEqual({ id: "o1", gasLimit: 0n, fee: 7n });
  });
});
`,
)
