// AssemblyScript's F64 and F32 classes carry parseFloat and the isNaN /
// isFinite / isInteger / isSafeInteger predicates (std/assembly/number.ts in
// asc 0.19.10). The shim's namespaces had only the constants, so
// `F64.parseFloat(text)` refused as an unknown graph-ts API. Expected values
// are asc 0.19.10's build of the same code.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Meter
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Meter
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Reading
      abis:
        - name: Meter
          file: ./abis/Meter.json
      eventHandlers:
        - event: Read(uint256)
          handler: handleRead
      file: ./src/meter.ts
`,
  ~schema=`
type Reading @entity {
  id: ID!
  text: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Meter.json",
      `[{"type":"event","name":"Read","anonymous":false,"inputs":[{"name":"n","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/meter.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleRead(event: any): void {
  let text = (F64.parseFloat("3.5e2") + 0.5).toString() + " " + (F32.parseFloat("0.1") == <f32>0.1 ? "f32" : "no") + " " +
    F64.isNaN(NaN).toString() + " " + F64.isInteger(3.0).toString() + " " + F64.isSafeInteger(9007199254740992.0).toString() + " " +
    F64.isFinite(Infinity).toString() + " " + F32.isInteger(2.5).toString();
  let reading = new Entity();
  reading.setString("text", text);
  store.set("Reading", "r", reading);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("F64 and F32 statics", () => {
  it("parse and test floats as AssemblyScript's do", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [{ contract: "Meter", event: "Read", params: { n: 1n } }] } } });
    t.expect(await indexer.Reading.getAll()).toEqual([{ id: "r", text: "350.5 f32 true true false false false" }]);
  });
});
`,
)
