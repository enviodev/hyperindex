// Two things AssemblyScript accepts that Node didn't:
// - AssemblyScript's DataView takes a u64 in `setUint64`/`getUint64` (Ekubo
//   builds its ids that way); JavaScript's spells it `setBigUint64`, and has no
//   `setUint64` at all.
// - `matchstick-as` re-exports graph-ts' `log`, and Beefy's mappings import it
//   from there. Only `@graphprotocol/graph-ts` reached the shim, so the import
//   failed at link time.
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
import { BigInt, Bytes, Entity, store } from "@graphprotocol/graph-ts";
import { log } from "matchstick-as/assembly/index";

export function handlePoolInitialized(event: any): void {
  const id = new Bytes(16);
  const view = new DataView(id.buffer);
  view.setUint64(0, event.block.number.toU64(), false);
  view.setUint32(8, 7, false);
  view.setUint32(12, event.logIndex.toU32(), false);
  log.info("initialized {}", [id.toHexString()]);

  let entity = new Entity();
  entity.setBigInt("back", BigInt.fromU64(view.getUint64(0, false)));
  store.set("Init", id.toHexString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("AssemblyScript's standard library and helper imports", () => {
  it("run as they do under asc", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Core", event: "PoolInitialized", params: { poolId: 1n }, block: { number: 258 }, logIndex: 3 },
          ],
        },
      },
    });
    t.expect(await indexer.Init.getAll()).toEqual([
      { id: "0x00000000000001020000000700000003", back: 258n },
    ]);
  });
});
`,
)
