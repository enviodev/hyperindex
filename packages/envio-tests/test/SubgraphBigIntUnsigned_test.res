// graph-ts reads a BigInt's minimal two's-complement little-endian bytes,
// zero-padded, for `toU32()`/`toU64()`: -1 is the byte 0xff, so 255, and only a
// value whose bytes don't fit overflows. Clober's `(tick.toU32() << 8) >> 8`
// relies on it; the shim refused every negative.
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
  month: String!
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
  let values: string[] = [
    BigInt.fromI32(-1).toU32().toString(),
    BigInt.fromI32(-256).toU32().toString(),
    BigInt.fromI32(-100).toU32().toString(),
    BigInt.fromString("4294967295").toU32().toString(),
    BigInt.fromI32(-1).toU64().toString(),
    BigInt.fromI32(7).toU64().toString(),
  ];
  let entity = new Entity();
  entity.setBigInt("back", BigInt.fromI32(0));
  entity.setString("month", values.join(","));
  store.set("Init", "u", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("BigInt.toU32() and toU64()", () => {
  it("read the minimal two's-complement bytes zero-padded, as graph-ts does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Core",
              event: "PoolInitialized",
              params: { poolId: 1n },
              block: { number: 258, timestamp: 1760400000 },
              logIndex: 3,
            },
          ],
        },
      },
    });
    t.expect(await indexer.Init.getAll()).toEqual([
      { id: "u", back: 0n, month: "255,65280,156,4294967295,255,7" },
    ]);
  });
});
`,
)
