// A manifest can hang typed values off a data source, and the mapping reads
// them back through `dataSource.context()` — Balancer gates its writes on one.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Vault
    network: mainnet
    context:
      storeEventsFrom:
        type: BigInt
        data: '100'
      poolKind:
        type: String
        data: weighted
      enabled:
        type: Bool
        data: true
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Vault
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Swap
      abis:
        - name: Vault
          file: ./abis/Vault.json
      eventHandlers:
        - event: Swap(uint256)
          handler: handleSwap
      file: ./src/vault.ts
`,
  ~schema=`
type Swap @entity {
  id: ID!
  kind: String!
  enabled: Boolean!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Vault.json",
      `[{"type":"event","name":"Swap","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/vault.ts",
      `
import { dataSource, Entity, store } from "@graphprotocol/graph-ts";

export function handleSwap(event: any): void {
  let storeEventsFrom = dataSource.context().get("storeEventsFrom");
  if (storeEventsFrom && event.block.number < storeEventsFrom.toBigInt().toI32()) {
    return;
  }

  let entity = new Entity();
  entity.setString("kind", dataSource.context().getString("poolKind"));
  entity.setBoolean("enabled", dataSource.context().getBoolean("enabled"));
  store.set("Swap", event.block.number.toString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const swap = (blockNumber: number) => ({
  contract: "Vault" as const,
  event: "Swap" as const,
  params: { amount: 1n },
  block: { number: blockNumber },
});

describe("dataSource.context()", () => {
  it("serves the manifest's typed values", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { startBlock: 0, endBlock: 300, simulate: [swap(50), swap(150)] } },
    });

    // Block 50 is below storeEventsFrom, so only the later swap is written.
    t.expect(await indexer.Swap.getAll()).toEqual([
      { id: "150", kind: "weighted", enabled: true },
    ]);
  });
});
`,
)
