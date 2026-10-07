// graph-node rounds every BigDecimal it makes to 34 significant digits, through
// the `bigdecimal` 0.1.2 it pins for determinism — positives half up, negatives
// truncated at what that crate counts as 34 digits. A subgraph's stored values
// carry that rounding, residues included: a balance that nets to zero in exact
// arithmetic doesn't on graph-node. The expected strings are that crate's own
// output for the same operations, and fixtures/graph-node-bigdecimal holds a
// few hundred more that its generator computes with that crate.
@module("node:fs") external readFileSync: (string, string) => string = "readFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@val external importMetaUrl: string = "import.meta.url"

let vectors = readFileSync(
  pathJoin([
    pathDirname(fileURLToPath(importMetaUrl)),
    "fixtures",
    "graph-node-bigdecimal",
    "vectors.json",
  ]),
  "utf8",
)

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Probe
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Probe
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Result
      abis:
        - name: Probe
          file: ./abis/Probe.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/probe.ts
`,
  ~schema=`
type Result @entity {
  id: ID!
  value: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Probe.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    ("src/vectors.ts", `export const vectors: string[][] = ${vectors};`),
    (
      "src/probe.ts",
      `
import { BigDecimal, Entity, store } from "@graphprotocol/graph-ts";
import { vectors } from "./vectors";

function d(value: string): BigDecimal {
  return BigDecimal.fromString(value);
}

function save(id: string, value: BigDecimal): void {
  let result = new Entity();
  result.setString("value", value.toString());
  store.set("Result", id, result);
}

export function handlePing(event: any): void {
  save("plus", d("1234567890.123456789012345678901234567").plus(d("0.000000000000000000000000000001")));
  save("minus", d("1000000000000000000.1234567890123456789").minus(d("1000000000000000000")));
  save("times", d("1.234567890123456789012345678901234567").times(d("3")));
  save("timesNegative", d("-1.234567890123456789012345678901234567").times(d("3")));
  save("divThird", d("1").div(d("3")));
  save("divTwoThirds", d("2").div(d("3")));
  save("divNegative", d("-2").div(d("3")));
  save("fromString", d("1.2345678901234567890123456789012345678"));
  save("fromStringNegative", d("-1.2345678901234567890123456789012345678"));
  save("wideInteger", d("12345678901234567890123456789012345678901"));
  // The F21 shape: two sides of a balance, equal in exact arithmetic.
  let side = d("123.456789012345678901234567890123456").times(d("7.000000000000000000000000000000001"));
  save("residue", side.minus(d("864.1975230864197530864197530864197530")));

  let mismatches: string[] = [];
  for (let i = 0; i < vectors.length; i++) {
    let op = vectors[i][0];
    let a = d(vectors[i][1]);
    let b = d(vectors[i][2]);
    let got = op == "plus" ? a.plus(b) : op == "minus" ? a.minus(b) : op == "times" ? a.times(b) : op == "div" ? a.div(b) : a;
    if (got.toString() != vectors[i][3]) {
      mismatches.push(vectors[i].join(" ") + " got " + got.toString());
    }
  }
  save("vectors", mismatches.length == 0 ? "all match" : mismatches.join("\\n"));
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("BigDecimal arithmetic", () => {
  it("rounds every result to graph-node's 34 significant digits", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Probe", event: "Ping", params: { nonce: 1n } }] } },
    });

    const results = Object.fromEntries((await indexer.Result.getAll()).map((r) => [r.id, r.value]));
    t.expect(results).toEqual({
      plus: "1234567890.123456789012345678901235",
      minus: "0.123456789012346",
      times: "3.703703670370370367037037036703705",
      timesNegative: "-3.7037036703703703670370370367037035",
      divThird: "0.3333333333333333333333333333333333",
      divTwoThirds: "0.6666666666666666666666666666666667",
      divNegative: "-0.66666666666666666666666666666666666",
      fromString: "1.234567890123456789012345678901235",
      fromStringNegative: "-1.2345678901234567890123456789012345",
      wideInteger: "12345678901234567890123456789012350000000",
      residue: "-0.0000000000000007777777778555552",
      vectors: "all match",
    });
  });
});
`,
)
