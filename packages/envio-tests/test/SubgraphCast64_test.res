// A cast to i64 or u64 is a 64-bit integer, which the shim holds as a bigint:
// a float truncates toward zero, an i32 sign-extends (so -1 as u64 is
// 2^64 - 1), and a u64 reinterprets as an i64. The casts were left as they
// were, so `BigInt.fromI64(<i64>price)` of a float threw and `big as i64` kept
// the u64. isize and usize are i32 and u32 on wasm32. Expected values are asc
// 0.19.10's build of this code.
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
        - event: Read(uint256,int256)
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
      `[{"type":"event","name":"Read","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false},{"name":"n","type":"int256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/meter.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

export function handleRead(event: any): void {
  let x = parseFloat("3.7");
  let n: i32 = event.params.n.toI32();
  let u: u32 = BigInt.fromString("4294967295").toU32();
  let big: u64 = event.params.amount.toU64();
  let a = <i64>x;
  let b = <i64>(-x);
  let c = <u64>n;
  let d = <i64>u;
  let e = big as i64;
  let f = (n as i64) * 1000000000000;
  let g = <isize>(n + 1);
  let reading = new Entity();
  reading.setString("casts", a.toString() + " " + b.toString() + " " + c.toString() + " " + d.toString() + " " + e.toString() + " " + f.toString() + " " + g.toString() + " " + BigInt.fromI64(<i64>x).toString());
  store.set("Reading", "r", reading);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("64-bit casts", () => {
  it("convert to the integer asc computes", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Meter", event: "Read", params: { amount: 18446744073709551615n, n: -1n } }] } },
    });
    t.expect(await indexer.Reading.getAll()).toEqual([{ id: "r", casts: "3 -3 18446744073709551615 4294967295 -1 -1000000000000 0 3" }]);
  });
});
`,
)
