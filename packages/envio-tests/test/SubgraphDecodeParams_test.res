// graph-node v0.45 adds `ethereum.decodeParams(types, data)` for apiVersion
// 0.0.10 (runtime/wasm/src/host_exports.rs `ethereum_decode_params`): alloy's
// `abi_decode_params`, which reads a top-level tuple's fields as a sequence of
// parameters, the way calldata holds them, where `ethereum.decode` expects one
// value behind an offset word. A failure is null, as for `decode`.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.3.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Safe
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Safe
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.10
      language: wasm/assemblyscript
      entities:
        - Execution
      abis:
        - name: Safe
          file: ./abis/Safe.json
      eventHandlers:
        - event: Executed(bytes)
          handler: handleExecuted
      file: ./src/safe.ts
`,
  ~schema=`
type Execution @entity {
  id: ID!
  decoded: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Safe.json",
      `[{"type":"event","name":"Executed","anonymous":false,"inputs":[{"name":"data","type":"bytes","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/safe.ts",
      `
import { Bytes, Entity, ethereum, store } from "@graphprotocol/graph-ts";

export function handleExecuted(event: any): void {
  const data: Bytes = event.parameters[0].value.toBytes();
  const params = ethereum.decodeParams("(address,uint256,bytes)", data)!.toTuple();
  const decoded = [
    params[0].toAddress().toHexString(),
    params[1].toBigInt().toString(),
    params[2].toBytes().toHexString(),
    ethereum.decodeParams("(address,uint256,bytes)", Bytes.fromHexString("0x1234")) === null ? "null" : "value",
  ];
  const execution = new Entity();
  execution.setString("decoded", decoded.join(","));
  store.set("Execution", "e", execution);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const data =
  "0x0000000000000000000000002222222222222222222222222222222222222222" +
  "000000000000000000000000000000000000000000000000000000000000002a" +
  "0000000000000000000000000000000000000000000000000000000000000060" +
  "0000000000000000000000000000000000000000000000000000000000000004" +
  "deadbeef00000000000000000000000000000000000000000000000000000000";

describe("ethereum.decodeParams", () => {
  it("reads a tuple's fields as top-level parameters", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Safe", event: "Executed", params: { data } }] } },
    });
    t.expect(await indexer.Execution.getAll()).toEqual([
      { id: "e", decoded: "0x2222222222222222222222222222222222222222,42,0xdeadbeef,null" },
    ]);
  });
});
`,
)
