// `array.sort()` without a comparator takes AssemblyScript's default one
// (std/assembly/util/sort.ts COMPARATOR in asc 0.19.10): numbers by value,
// strings by their code units, and any other reference with `a > b` and
// `a < b`, which graph-ts' BigInt and BigDecimal overload. JavaScript's default
// sorts every element as a string, so `[5, 1, 10, 2]` came out 1,10,2,5 and
// Beanstalk's `field.plotIndexes.sort()` of BigInts put 10 before 9.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Field
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Field
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Plots
      abis:
        - name: Field
          file: ./abis/Field.json
      eventHandlers:
        - event: Sow(uint256)
          handler: handleSow
      file: ./src/field.ts
`,
  ~schema=`
type Plots @entity {
  id: ID!
  numbers: String!
  indexes: [BigInt!]!
  decimals: String!
  names: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Field.json",
      `[{"type":"event","name":"Sow","anonymous":false,"inputs":[{"name":"index","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/field.ts",
      `
import { BigDecimal, BigInt, Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleSow(event: any): void {
  let numbers: i32[] = [5, 1, 10, 2, -3];
  numbers.sort();
  let indexes: BigInt[] = [BigInt.fromI32(9), BigInt.fromI32(100), BigInt.fromI32(10), event.params.index];
  let sorted = indexes.sort();
  let decimals: BigDecimal[] = [BigDecimal.fromString("2.5"), BigDecimal.fromString("10"), BigDecimal.fromString("-1")];
  decimals.sort();
  let names: string[] = ["b", "a", "C", "aa"];
  names.sort();
  let entity = new Entity();
  entity.setString("numbers", numbers.join(","));
  entity.set("indexes", Value.fromBigIntArray(sorted));
  entity.setString("decimals", decimals.map<string>((d: BigDecimal) => d.toString()).join(","));
  entity.setString("names", names.join(","));
  store.set("Plots", "p", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("sort() without a comparator", () => {
  it("sorts as AssemblyScript's default comparator does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Field", event: "Sow", params: { index: 2n } }] } },
    });
    t.expect(await indexer.Plots.getAll()).toEqual([
      { id: "p", numbers: "-3,1,2,5,10", indexes: [2n, 9n, 10n, 100n], decimals: "-1,2.5,10", names: "C,a,aa,b" },
    ]);
  });
});
`,
)
