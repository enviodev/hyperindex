// graph-node's `typeConversion.bigIntToHex` (runtime/wasm/src/host_exports.rs
// `big_int_to_hex`) writes the magnitude's big-endian bytes as hex with the
// leading zeros trimmed, "0x0" for zero, and drops the sign: -255 is "0xff".
// The shim used viem's `toHex`, which throws on a negative value.
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
  values: String!
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
    BigInt.fromI32(-255).toHexString(),
    BigInt.fromString("-4096").toHex(),
    BigInt.fromI32(0).toHexString(),
    BigInt.fromString("1208925819614629174706176").toHexString(),
  ];
  let entity = new Entity();
  entity.setString("values", values.join(","));
  store.set("Init", "u", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("BigInt.toHexString()", () => {
  it("writes the magnitude in hex, as graph-node does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Core", event: "PoolInitialized", params: { poolId: 1n } }] } },
    });
    t.expect(await indexer.Init.getAll()).toEqual([{ id: "u", values: "0xff,0x1000,0x0,0x100000000000000000000" }]);
  });
});
`,
)
