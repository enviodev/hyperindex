// swaap-labs/swaap-subgraph-v1 (Balancer v1's pools) matches its anonymous
// `LOG_CALL(bytes4 indexed sig, address indexed caller, bytes data)` on
// topic0, the called function's selector, one handler per function. graph-node
// keys a handler on `topic0` when the manifest gives one
// (`MappingEventHandler::topic0`) and decodes the anonymous event from all of
// its topics. The translation refused it.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Call
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: LOG_CALL(indexed bytes4,indexed address,bytes)
          topic0: "0x34e1990700000000000000000000000000000000000000000000000000000000"
          handler: handleSetSwapFee
        - event: LOG_CALL(indexed bytes4,indexed address,bytes)
          topic0: "0x4bb278f300000000000000000000000000000000000000000000000000000000"
          handler: handleFinalize
      file: ./src/pool.ts
`,
  ~schema=`
type Call @entity {
  id: ID!
  handler: String!
  sig: Bytes!
  caller: Bytes!
  data: Bytes!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"LOG_CALL","anonymous":true,"inputs":[{"name":"sig","type":"bytes4","indexed":true},{"name":"caller","type":"address","indexed":true},{"name":"data","type":"bytes","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/pool.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";

function save(handler: string, event: any): void {
  const call = new Entity();
  call.set("handler", Value.fromString(handler));
  call.set("sig", Value.fromBytes(event.params.sig));
  call.set("caller", Value.fromBytes(event.params.caller));
  call.set("data", Value.fromBytes(event.params.data));
  store.set("Call", handler, call);
}

export function handleSetSwapFee(event: any): void {
  save("setSwapFee", event);
}

export function handleFinalize(event: any): void {
  save("finalize", event);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const caller = "0xcccccccccccccccccccccccccccccccccccccccc";
const call = (event: string, sig: string) => ({
  contract: "Pool",
  event,
  params: { sig, caller, data: "0x1234" },
});

describe("anonymous events matched on topic0", () => {
  it("runs each handler on its own topic0", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            call("LOG_CALL", "0x34e1990700000000000000000000000000000000000000000000000000000000"),
            call("LOG_CALL_1", "0x4bb278f300000000000000000000000000000000000000000000000000000000"),
          ],
        },
      },
    });

    const hex = (bytes: Uint8Array) => "0x" + Buffer.from(bytes).toString("hex");
    t.expect(
      (await indexer.Call.getAll()).map((row: any) => ({
        id: row.id,
        sig: hex(row.sig),
        caller: hex(row.caller),
        data: hex(row.data),
      })).sort((a: any, b: any) => a.id.localeCompare(b.id)),
    ).toEqual([
      { id: "finalize", sig: "0x4bb278f3", caller, data: "0x1234" },
      { id: "setSwapFee", sig: "0x34e19907", caller, data: "0x1234" },
    ]);
  });
});
`,
)
