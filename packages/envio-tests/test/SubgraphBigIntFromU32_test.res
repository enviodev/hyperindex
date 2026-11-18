// `BigInt.fromU32(x: u32)` reads its argument as AssemblyScript's u32: the
// same 32 bits as an i32 an expression like `1 << 31` produces, so 2^31, not
// -2^31. JavaScript hands the shim the signed number; it is read as unsigned,
// as graph-ts' `ByteArray.fromU32` + `fromUnsignedBytes` see its bits.
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
    BigInt.fromU32(1 << 31).toString(),
    BigInt.fromU32(~0).toString(),
    BigInt.fromU32(7).toString(),
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

describe("BigInt.fromU32()", () => {
  it("reads its argument's bits as unsigned", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Core", event: "PoolInitialized", params: { poolId: 1n } }] } },
    });
    t.expect(await indexer.Init.getAll()).toEqual([{ id: "u", values: "2147483648,4294967295,7" }]);
  });
});
`,
)
