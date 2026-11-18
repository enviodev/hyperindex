// Things AssemblyScript accepts that Node didn't:
// - AssemblyScript's DataView takes a u64 in `setUint64`/`getUint64` (Ekubo
//   builds its ids that way); JavaScript's spells it `setBigUint64`, and has no
//   `setUint64` at all.
// - `matchstick-as` re-exports graph-ts' `log`, and Beefy's mappings import it
//   from there. Only `@graphprotocol/graph-ts` reached the shim, so the import
//   failed at link time.
// - 10 ** i64 is an i64 power: JavaScript's ** refuses to mix a bigint with a
//   number (harvest-base's normalizePrecision).
// - An i64 times an integer literal is an i64, and `new Date(ms)` takes one:
//   p2p.me's `timestamp.toI64() * 1000` mixed a bigint with a number, which
//   JavaScript refuses, and `new Date()` refuses a bigint too.
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
  power: BigInt!
  bigPower: BigInt!
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

  let ms = event.block.timestamp.toI64() * 1000;
  let date = new Date(ms);
  let seconds = date.getTime() / 1000;

  // 10 ** x with an i64 exponent is an i64 power (harvest-base's
  // normalizePrecision), and BigInt ** 10 is graph-ts' BigInt.pow.
  let power = 10 ** event.logIndex.toI64();
  let bigPower = BigInt.fromI32(2) ** 10;

  let entity = new Entity();
  entity.setBigInt("power", BigInt.fromI64(power));
  entity.setBigInt("bigPower", bigPower);
  entity.setBigInt("back", BigInt.fromU64(view.getUint64(0, false)));
  entity.setString("month", date.getUTCFullYear().toString() + "-" + (date.getUTCMonth() + 1).toString() + ":" + seconds.toString());
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
      { id: "0x00000000000001020000000700000003", back: 258n, month: "2025-10:1760400000", power: 1000n, bigPower: 1024n },
    ]);
  });
});
`,
)
