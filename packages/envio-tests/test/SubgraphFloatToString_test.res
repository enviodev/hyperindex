// AssemblyScript prints a float that holds a whole number with a trailing
// ".0" (std/assembly/util/number.ts dtoa: "100.0", "3.0", "0.0" for -0), and
// otherwise as JavaScript does. A float's `toString()` printed JavaScript's
// "100", so an id or a String field built from one differed from graph-node's.
// Expected values are asc 0.19.10's build of the same code.
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
  let n: i32 = event.params.n.toI32();
  let whole = parseFloat("100");
  let half: f64 = 2.5;
  let negativeZero = -0.0;
  let text = whole.toString() + " " + Math.floor(half).toString() + " " + (n as f64).toString() + " " +
    half.toString() + " " + (1e21).toString() + " " + negativeZero.toString() + " " + (whole / 8).toString() + " " + n.toString();
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

describe("a float's toString()", () => {
  it("prints as AssemblyScript's dtoa does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [{ contract: "Meter", event: "Read", params: { n: 7n } }] } } });
    t.expect(await indexer.Reading.getAll()).toEqual([{ id: "r", text: "100.0 2.0 7.0 2.5 1e+21 0.0 12.5 7" }]);
  });
});
`,
)
