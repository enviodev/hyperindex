// AssemblyScript's BigInt is a byte array and `new BigInt(0)` makes an empty
// one, which is zero. Balancer v2 folds a pool's deltas from `new BigInt(0)`;
// the shim's constructor took only a JavaScript bigint, so the first `plus`
// failed with "Cannot mix BigInt and other types".
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Core
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Core
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Init
      abis:
        - name: Core
          file: ./abis/Core.json
      eventHandlers:
        - event: PoolInitialized(uint256)
          handler: handlePoolInitialized
      file: ./src/core.ts
`,
  ~schema=`
type Init @entity {
  id: ID!
  back: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Core.json",
      `[{"type":"event","name":"PoolInitialized","anonymous":false,"inputs":[{"name":"poolId","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/core.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

export function handlePoolInitialized(event: any): void {
  let deltas: BigInt[] = [event.params.poolId, BigInt.fromI32(5)];
  let total: BigInt = deltas.reduce<BigInt>((sum, amount) => sum.plus(amount), new BigInt(0));
  let entity = new Entity();
  entity.setBigInt("back", total);
  store.set("Init", "total", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("new BigInt(0)", () => {
  it("is zero", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Core",
              event: "PoolInitialized",
              params: { poolId: 37n },
              block: { number: 258, timestamp: 1760400000 },
              logIndex: 3,
            },
          ],
        },
      },
    });
    t.expect(await indexer.Init.getAll()).toEqual([{ id: "total", back: 42n }]);
  });
});
`,
)
