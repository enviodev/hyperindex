// graph-node's `Address.fromString` is `string_to_h160`, which trims a leading
// `0x` and parses the rest: the prefix is optional. Livepeer keeps its
// contract addresses as bare hex ("35Bcf3c3...") at module scope, and the shim
// refused them, failing the mapping's load.
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
import { Address, BigInt, Entity, store } from "@graphprotocol/graph-ts";

const BARE = "35Bcf3c30594191d53231E4FF333E8A770453e40";
const MANAGER = Address.fromString(BARE);

export function handlePoolInitialized(event: any): void {
  let entity = new Entity();
  entity.setBigInt("back", event.params.poolId);
  store.set("Init", MANAGER.toHexString() + ":" + Address.fromString("0x" + BARE).toHexString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Address.fromString", () => {
  it("takes bare hex", async (t) => {
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
    t.expect(await indexer.Init.getAll()).toEqual([{ id: "0x35bcf3c30594191d53231e4ff333e8a770453e40:0x35bcf3c30594191d53231e4ff333e8a770453e40", back: 37n }]);
  });
});
`,
)
