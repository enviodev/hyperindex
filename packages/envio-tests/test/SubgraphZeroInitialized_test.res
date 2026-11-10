// AssemblyScript zero-initializes what has no initializer: a class field or a
// local of an integer or float type is 0, a bool is false, a reference null
// (asc 0.19.10 `makeZero`). JavaScript leaves them `undefined`, so
// `this.count += 1` was NaN and `flag == false` didn't hold.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Check
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(address)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Check @entity {
  id: ID!
  count: Int!
  ratio: String!
  flagIsFalse: Boolean!
  labelIsNull: Boolean!
  sum: Int!
  staticCount: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"owner","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

class Totals {
  count: i32;
  ratio: f64;
  flag: bool;
  label: string | null;
  static instances: i32;
}

function sum(values: i32[]): i32 {
  let total: i32;
  for (let i = 0; i < values.length; i++) {
    total += values[i];
  }
  return total;
}

export function handleNewOwner(event: any): void {
  let totals = new Totals();
  totals.count += 2;
  totals.ratio += 0.5;

  let check = new Entity();
  check.setI32("count", totals.count);
  check.setString("ratio", totals.ratio.toString());
  check.setBoolean("flagIsFalse", totals.flag == false);
  check.setBoolean("labelIsNull", totals.label == null);
  check.setI32("sum", sum([1, 2, 3]));
  check.setI32("staticCount", Totals.instances + 1);
  store.set("Check", "c1", check);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a field or local without an initializer", () => {
  it("starts at the zero of its type", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Registry", event: "NewOwner", params: { owner: "0x2222222222222222222222222222222222222222" } },
          ],
        },
      },
    });

    t.expect(await indexer.Check.getOrThrow("c1")).toEqual({
      id: "c1",
      count: 2,
      ratio: "0.5",
      flagIsFalse: true,
      labelIsNull: true,
      sum: 6,
      staticCount: 1,
    });
  });
});
`,
)
