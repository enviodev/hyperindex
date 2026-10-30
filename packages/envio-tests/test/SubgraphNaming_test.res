// A subgraph names its entities and data sources however it likes; envio
// capitalizes both. The mapping still uses the names it was written with.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: crvUSD
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - pool_created
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Created(uint256)
          handler: handleCreated
      file: ./src/pool.ts
templates:
  - kind: ethereum/contract
    name: pair
    network: mainnet
    source:
      abi: Pool
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - pool_created
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Created(uint256)
          handler: handleCreated
      file: ./src/pool.ts
`,
  ~schema=`
type pool_created @entity {
  id: ID!
  count: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/pool.ts",
      `
import { BigInt, DataSourceTemplate, Entity, store } from "@graphprotocol/graph-ts";

export function handleCreated(event: any): void {
  let existing = store.get("pool_created", "pool");
  let count = existing === null ? BigInt.fromI32(0) : existing.getBigInt("count");
  let entity = new Entity();
  entity.setString("id", "pool");
  entity.setBigInt("count", count.plus(event.params.amount));
  store.set("pool_created", "pool", entity);
  DataSourceTemplate.create("pair", ["0x2222222222222222222222222222222222222222"]);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("names as the subgraph wrote them", () => {
  it("reaches a lowercase entity from a lowercase data source and template", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "CrvUSD", event: "Created", params: { amount: 2n }, block: { number: 10 } },
            {
              contract: "Pair",
              event: "Created",
              params: { amount: 3n },
              srcAddress: "0x2222222222222222222222222222222222222222",
              block: { number: 20 },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Pool_created.getAll()).toEqual([{ id: "pool", count: 5n }]);
  });
});
`,
)
