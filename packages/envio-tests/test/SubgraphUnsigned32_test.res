// A u32 is unsigned in AssemblyScript: `<<` keeps 32 bits of an unsigned
// result, `>>` on it shifts in zeros, and `|`, `&`, `^` give unsigned values.
// JavaScript's bitwise operators give a signed int32, so Clober's 24-bit tick
// `(tick.toU32() << 8) >> 8` came out negative and Ekubo's big-endian word
// `(data[i] as u32) << 24 | …` too. A u32 handed to `BigInt.fromU32` is its
// bits, whatever expression made it.
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
  tick: BigInt!
  word: BigInt!
  high: Int!
  shifted: BigInt!
  signed: Int!
  fromNegative: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

function wordAt(data: u8[], start: i32): u32 {
  return ((data[start] as u32) << 24) |
    ((data[start + 1] as u32) << 16) |
    ((data[start + 2] as u32) << 8) |
    (data[start + 3] as u32);
}

export function handleNewOwner(event: any): void {
  let tick: u32 = 4294967196;
  let all: u32 = 4294967295;
  let low: u32 = 0x00ffffff;
  let negative: i32 = -256;

  let check = new Entity();
  check.setBigInt("tick", BigInt.fromU32((tick << 8) >> 8));
  check.setBigInt("word", BigInt.fromU32(wordAt([0xff, 0x01, 0x02, 0x03], 0)));
  check.setI32("high", all >> 16);
  check.setBigInt("shifted", BigInt.fromU32(low << 8));
  check.setI32("signed", negative >> 4);
  check.setBigInt("fromNegative", BigInt.fromU32(negative));
  store.set("Check", "c1", check);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("u32 bit operations", () => {
  it("compute unsigned results, as AssemblyScript does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 1n } }] } },
    });
    t.expect(await indexer.Check.getOrThrow("c1")).toEqual({
      id: "c1",
      tick: 16777116n,
      word: 4278256131n,
      high: 65535,
      shifted: 4294967040n,
      signed: -16,
      fromNegative: 4294967040n,
    });
  });
});
`,
)
