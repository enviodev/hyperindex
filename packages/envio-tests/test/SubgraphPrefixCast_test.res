// AssemblyScript has two spellings of a numeric cast, `x as u8` and `<u8>x`,
// and both convert: an integer wraps to the narrower width, a float truncates
// toward zero, and an i64 cast to f64 is a float. Only `as` with an integer
// type was rewritten; `<T>x` lost its type with the rest of TypeScript's, and an
// i64 (a bigint here) cast to f64 stayed a bigint, which JavaScript refuses to
// mix with a fraction. Expected values are asc 0.19.10's build of this code.
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
        - event: Read(uint256,uint256)
          handler: handleRead
      file: ./src/meter.ts
`,
  ~schema=`
type Reading @entity {
  id: ID!
  casts: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Meter.json",
      `[{"type":"event","name":"Read","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false},{"name":"n","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/meter.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleRead(event: any): void {
  let big: i64 = event.params.amount.toI64();
  let n: i32 = event.params.n.toI32();
  let x: f64 = 3.75;
  let a = <u8>n;
  let b = <i32>x;
  let c = <i8>(n - 100);
  let d = (big as f64) + 0.5;
  let e = <f64>big * 0.125;
  let f = <f32>x;
  let g = <u16>(n * 300);
  let reading = new Entity();
  reading.setString("casts", a.toString() + " " + b.toString() + " " + c.toString() + " " + d.toString() + " " + e.toString() + " " + f.toString() + " " + g.toString());
  store.set("Reading", "r", reading);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("numeric casts", () => {
  it("convert in both spellings, as asc compiles them", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Meter", event: "Read", params: { amount: 1234567n, n: 300n } }] } },
    });
    t.expect(await indexer.Reading.getAll()).toEqual([{ id: "r", casts: "44 3 -56 1234567.5 154320.875 3.75 24464" }]);
  });
});
`,
)
