// An i64 is a bigint here, and JavaScript refuses `&`, `|`, `^`, `<<` and `>>`
// between a bigint and a number ("Cannot mix BigInt and other types"), where
// AssemblyScript widens the i32 operand. Kiln's SSZ encoding of a deposit
// amount does `u32(amount & 0xffffffff)` on one.
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
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Check @entity {
  id: ID!
  low: BigInt!
  high: BigInt!
  shifted: BigInt!
  halved: BigInt!
  flagged: BigInt!
  narrow: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

const NUMBER_2_POW_32: i64 = 2 ** 32;

export function handleNewOwner(event: any): void {
  let amount: i64 = event.params.amount.toI64();
  let flags = 6;
  flags &= 3;

  let check = new Entity();
  check.setBigInt("low", BigInt.fromU32(u32(amount & 0xffffffff)));
  check.setBigInt("high", BigInt.fromU32(u32((amount / NUMBER_2_POW_32) & 0xffffffff)));
  check.setBigInt("shifted", BigInt.fromI64(amount << 2));
  check.setBigInt("halved", BigInt.fromI64(amount >> 1));
  check.setBigInt("flagged", BigInt.fromI64(amount | 1));
  check.setI32("narrow", flags);
  store.set("Check", "c1", check);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("bit operations on an i64", () => {
  it("compute in 64 bits, widening the i32 side", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { amount: 32000000000n } }] },
      },
    });
    t.expect(await indexer.Check.getOrThrow("c1")).toEqual({
      id: "c1",
      low: 1935228928n,
      high: 7n,
      shifted: 128000000000n,
      halved: 16000000000n,
      flagged: 32000000001n,
      narrow: 2,
    });
  });
});
`,
)
