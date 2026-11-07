// What a mapping reads back out of the store is typed by the schema, not by
// the shape the value happens to have in JS: a Bytes id and a String both
// arrive as strings, and a BigInt and an Int8 both as numbers. graph-node knows
// the difference statically from codegen, so the translator carries each
// field's declared type through to the runtime.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pool
        - Bundle
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: PoolCreated(int24,uint256)
          handler: handlePoolCreated
      file: ./src/factory.ts
`,
  ~schema=`
type Pool @entity {
  id: Bytes!
  liquidity: BigInt!
  price: BigDecimal!
  tick: Int!
}

type Bundle @entity {
  id: ID!
  pools: [Pool!]!
  probe: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"PoolCreated","anonymous":false,"inputs":[{"name":"tick","type":"int24","indexed":false},{"name":"liquidity","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/factory.ts",
      `
import { BigDecimal, BigInt, Bytes, Entity, store, Value } from "@graphprotocol/graph-ts";

export function handlePoolCreated(event: any): void {
  // An int24 is an i32 in AssemblyScript and a uint256 is a BigInt, so only one
  // of these two has .plus on it.
  let tick: i32 = event.params.tick;
  let liquidity: BigInt = event.params.liquidity;

  let pool = new Entity();
  pool.setBigInt("liquidity", liquidity.plus(BigInt.fromI32(tick)));
  pool.setBigDecimal("price", BigDecimal.fromString("1.5"));
  pool.setI32("tick", tick);
  store.set("Pool", "0xaaaa", pool);

  let bundle = new Entity();
  bundle.setString("probe", "");
  bundle.set("pools", Value.fromBytesArray([Bytes.fromHexString("0xaaaa")]));
  store.set("Bundle", "b1", bundle);

  let loadedBundle = store.get("Bundle", "b1")!;
  // A list of relations carries the target's ids, so each element is a Bytes.
  let first: Bytes = loadedBundle.pools[0];
  let loadedPool = store.get("Pool", first.toHexString())!;

  let probe = new Entity();
  probe.set("pools", Value.fromBytesArray([]));
  probe.setString(
    "probe",
    loadedPool.liquidity.plus(BigInt.fromI32(1)).toString() +
      "|" +
      loadedPool.price.times(BigDecimal.fromString("2")).toString() +
      "|" +
      (loadedPool.tick + 1).toString(),
  );
  store.set("Bundle", "b2", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a field's declared type", () => {
  it("survives the round trip through the store", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Factory", event: "PoolCreated", params: { tick: 9, liquidity: 100n } },
          ],
        },
      },
    });

    t.expect(await indexer.Bundle.getOrThrow("b2")).toEqual({
      id: "b2",
      pools: [],
      probe: "110|3|10",
    });
  });
});
`,
)
