// A mapping file that also holds matchstick fixtures imports `newMockEvent`
// from `matchstick-as` beside its handlers (Forta's do). `matchstick-as`
// resolves to the shim, which had no such export, so the file failed to link
// before any event ran.
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
import { newMockEvent } from "matchstick-as";

export function fixture(): any {
  return newMockEvent();
}

export function handlePoolInitialized(event: any): void {
  let mock = fixture();
  let entity = new Entity();
  entity.setBigInt("back", event.params.poolId.plus(mock.logIndex));
  store.set("Init", mock.address.toHexString() + ":" + mock.logType, entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("newMockEvent", () => {
  it("is importable and builds matchstick's defaults", async (t) => {
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
    t.expect(await indexer.Init.getAll()).toEqual([{ id: "0xa16081f360e3847006db660bae1c6d1b2e17ec2a:mock_log_type", back: 38n }]);
  });
});
`,
)
