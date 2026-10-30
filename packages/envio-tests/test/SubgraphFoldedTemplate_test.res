// A template that shares its name with a data source is folded into the same
// envio contract. Its handlers must still route by the data source's event
// names — an overload the template lists alone isn't the first of its name
// there — and, as on graph-node, the data source's handlers run for its own
// address and the template's for the ones it creates, never both.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
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
        - Seen
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePingOne
        - event: Ping(uint256,uint256)
          handler: handlePingTwo
        - event: Created(address)
          handler: handleCreated
      file: ./src/pool.ts
templates:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      abi: Pool
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Seen
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Ping(uint256,uint256)
          handler: handlePingTwo
      file: ./src/pool.ts
`,
  ~schema=`
type Seen @entity {
  id: ID!
  count: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"a","type":"uint256","indexed":false}]},{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"a","type":"uint256","indexed":false},{"name":"b","type":"uint256","indexed":false}]},{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"pool","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/pool.ts",
      `
import { Address, DataSourceTemplate, Entity, dataSource, store } from "@graphprotocol/graph-ts";

function seen(id: string): void {
  let entity = store.get("Seen", id);
  if (entity == null) {
    entity = new Entity();
    entity.setI32("count", 0);
  }
  entity.setI32("count", entity.getI32("count") + 1);
  store.set("Seen", id, entity);
}

export function handleCreated(event: any): void {
  let pool: Address = event.params.pool;
  DataSourceTemplate.create("Pool", [pool.toHexString()]);
}

export function handlePingOne(event: any): void {
  seen(dataSource.address().toHexString().slice(0, 4) + ":one:" + event.params.a.toString());
}

export function handlePingTwo(event: any): void {
  seen(dataSource.address().toHexString().slice(0, 4) + ":two:" + event.params.a.toString() + ":" + event.params.b.toString());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a template folded into a data source of the same name", () => {
  it("runs each overload's handler only for that overload", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Pool",
              event: "Created",
              params: { pool: "0x2222222222222222222222222222222222222222" },
              block: { number: 10 },
            },
            { contract: "Pool", event: "Ping", params: { a: 1n }, block: { number: 20 } },
            { contract: "Pool", event: "Ping_1", params: { a: 2n, b: 3n }, block: { number: 20 } },
            {
              contract: "Pool",
              event: "Ping_1",
              srcAddress: "0x2222222222222222222222222222222222222222",
              params: { a: 4n, b: 5n },
              block: { number: 20 },
            },
          ],
        },
      },
    });

    t.expect((await indexer.Seen.getAll()).sort((a, b) => a.id.localeCompare(b.id))).toEqual([
      { id: "0x11:one:1", count: 1 },
      { id: "0x11:two:2:3", count: 1 },
      { id: "0x22:two:4:5", count: 1 },
    ]);
  });
});
`,
)
