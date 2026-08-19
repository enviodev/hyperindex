// graph-ts represents integers as little-endian byte arrays, and reads them
// back the same way — `ByteArray.fromI32(1)` is `0x01000000`, and a signed byte
// array carries two's complement. Getting this wrong doesn't raise: it writes a
// different entity id, or turns a negative amount into a large positive one.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/token.ts
`,
  ~schema=`
type Probe @entity {
  id: ID!
  value: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { BigInt, ByteArray, Bytes, Entity, store } from "@graphprotocol/graph-ts";

function probe(id: string, value: string): void {
  let entity = new Entity();
  entity.setString("value", value);
  store.set("Probe", id, entity);
}

export function handlePing(event: any): void {
  probe("le", ByteArray.fromI32(1).toHexString());
  probe("roundTrip", ByteArray.fromI32(-1).toI32().toString());
  probe("i64", ByteArray.fromI64(-2).toI64().toString());
  probe("concat", Bytes.fromHexString("0xaabb").concatI32(1).toHexString());

  // A single 0xff byte is -1 read as signed and 255 read as unsigned.
  probe("signed", BigInt.fromSignedBytes(Bytes.fromHexString("0xff")).toString());
  probe("unsigned", BigInt.fromUnsignedBytes(Bytes.fromHexString("0xff")).toString());
  // Little-endian: the low byte comes first, so this is 1 rather than 256.
  probe("twoBytes", BigInt.fromUnsignedBytes(Bytes.fromHexString("0x0100")).toString());

  // graph-ts reads an empty array as zero rather than raising.
  probe("empty", ByteArray.empty().toI32().toString());
  probe("emptyBigInt", BigInt.fromUnsignedBytes(ByteArray.empty()).toString());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("byte order", () => {
  it("matches graph-ts for integers and signed bytes", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Ping", params: { nonce: 1n } }] },
      },
    });

    const value = async (id: string) => (await indexer.Probe.getOrThrow(id)).value;

    t.expect({
      le: await value("le"),
      roundTrip: await value("roundTrip"),
      i64: await value("i64"),
      concat: await value("concat"),
      signed: await value("signed"),
      unsigned: await value("unsigned"),
      twoBytes: await value("twoBytes"),
      empty: await value("empty"),
      emptyBigInt: await value("emptyBigInt"),
    }).toEqual({
      le: "0x01000000",
      roundTrip: "-1",
      i64: "-2",
      concat: "0xaabb01000000",
      signed: "-1",
      unsigned: "255",
      twoBytes: "1",
      empty: "0",
      emptyBigInt: "0",
    });
  });
});
`,
)
