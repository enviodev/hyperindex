// A BigInt IS its bytes in graph-ts, and mappings read them: Proof of Humanity's
// `biToBytes(bi)` pads to 32 bytes when `32 > bi.byteLength` and otherwise
// takes `ByteArray.fromBigInt(bi)`. The shim's BigInt kept no bytes, so its
// byteLength was 0 for every value and the key it built was 32 zeros plus the
// value (never 32 bytes), which broke the lookups that rebuilt it.
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
  note: String!
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
import { BigInt, ByteArray, Entity, store } from "@graphprotocol/graph-ts";

function biToBytes(bi: BigInt): ByteArray {
  return 32 > bi.byteLength
    ? new ByteArray(32 - bi.byteLength).concat(ByteArray.fromBigInt(bi))
    : ByteArray.fromBigInt(bi);
}

export function handlePoolInitialized(event: any): void {
  let lines: string[] = [
    BigInt.fromI32(0).byteLength.toString(),
    BigInt.fromI32(1).byteLength.toString(),
    BigInt.fromU32(1).byteLength.toString(),
    BigInt.fromI64(1).byteLength.toString(),
    BigInt.fromU64(1).byteLength.toString(),
    event.params.poolId.byteLength.toString(),
    BigInt.zero().byteLength.toString(),
    BigInt.fromI32(1).plus(BigInt.fromI32(1)).byteLength.toString(),
    biToBytes(BigInt.fromI32(1)).toHexString(),
    biToBytes(event.params.poolId).toHexString(),
  ];
  let entity = new Entity();
  entity.setBigInt("back", event.params.poolId);
  entity.setString("note", lines.join(" "));
  store.set("Init", "bytes", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("BigInt.byteLength", () => {
  it("is the byte count graph-ts holds the value in", async (t) => {
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
    t.expect(await indexer.Init.getAll()).toEqual([
      {
        id: "bytes",
        back: 37n,
        note: [
          "4", "4", "5", "8", "9", "1", "4", "1",
          "0x" + "00".repeat(28) + "01000000",
          "0x" + "00".repeat(31) + "25",
        ].join(" "),
      },
    ]);
  });
});
`,
)
