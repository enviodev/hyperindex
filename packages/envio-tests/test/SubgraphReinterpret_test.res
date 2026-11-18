// `reinterpret<T>(x)` is AssemblyScript's bit cast between an integer and a
// float of one width (std/assembly/builtins.ts: f32 <-> i32/u32, f64 <-> i64/u64).
// totalreclaw's protobuf decoder assembles a double's eight little-endian
// bytes into a u64 and reinterprets it as an f64; JavaScript has no such
// global, so its first Log stopped the run.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Edge
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Edge
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Fact
      abis:
        - name: Edge
          file: ./abis/Edge.json
      eventHandlers:
        - event: Log(bytes)
          handler: handleLog
      file: ./src/edge.ts
`,
  ~schema=`
type Fact @entity {
  id: ID!
  score: BigDecimal!
  doubleBits: BigInt!
  single: BigDecimal!
  singleBits: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Edge.json",
      `[{"type":"event","name":"Log","anonymous":false,"inputs":[{"name":"data","type":"bytes","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/edge.ts",
      `
import { BigDecimal, BigInt, Bytes, Entity, store } from "@graphprotocol/graph-ts";

export function handleLog(event: any): void {
  let data = event.params.data as Bytes;
  let bits: u64 = 0;
  for (let b = 0; b < 8; b++) {
    bits = bits | (u64(data[b]) << u64(8 * b));
  }
  let score = reinterpret<f64>(bits);
  let single = reinterpret<f32>(1069547520);

  let fact = new Entity();
  fact.setBigDecimal("score", BigDecimal.fromString(score.toString()));
  fact.setBigInt("doubleBits", BigInt.fromI64(reinterpret<i64>(score)));
  fact.setBigDecimal("single", BigDecimal.fromString(single.toString()));
  fact.setI32("singleBits", reinterpret<i32>(f32(-2.5)));
  store.set("Fact", "f1", fact);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("reinterpret<T>", () => {
  it("casts the bits between integers and floats, as AssemblyScript does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Edge", event: "Log", params: { data: "0x000000000000d03f" } }] } },
    });
    const fact = await indexer.Fact.getOrThrow("f1");
    t.expect({ ...fact, score: fact.score.toString(), single: fact.single.toString() }).toEqual({
      id: "f1",
      score: "0.25",
      doubleBits: 4598175219545276416n,
      single: "1.5",
      singleBits: -1071644672,
    });
  });
});
`,
)
