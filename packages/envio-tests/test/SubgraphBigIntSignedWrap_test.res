// graph-ts' `toI32()`/`toI64()` (ByteArray, which BigInt defers to) check only
// that the bytes past the width are the sign padding, then read the low bytes
// as two's complement: a uint32 of 2^32 - 1 is `ff ff ff ff 00` and reads as
// -1. The shim refused anything outside the signed range, so poa-box's
// `event.params.maxMembers.toI32()` on `type(uint32).max` stopped the run.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Org
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Org
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Subject
      abis:
        - name: Org
          file: ./abis/Org.json
      eventHandlers:
        - event: SubjectCreated(uint32,uint64)
          handler: handleSubjectCreated
      file: ./src/org.ts
`,
  ~schema=`
type Subject @entity {
  id: ID!
  maxMembers: Int!
  values: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Org.json",
      `[{"type":"event","name":"SubjectCreated","anonymous":false,"inputs":[{"name":"maxMembers","type":"uint32","indexed":false},{"name":"cap","type":"uint64","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/org.ts",
      `
import { BigInt, Bytes, Entity, store } from "@graphprotocol/graph-ts";

function overflows(run: () => void): string {
  try {
    run();
    return "fits";
  } catch (error) {
    return "overflow";
  }
}

export function handleSubjectCreated(event: any): void {
  let values: string[] = [
    event.parameters[1].value.toBigInt().toI64().toString(),
    BigInt.fromString("2147483648").toI32().toString(),
    BigInt.fromString("-4294967296").toI32().toString(),
    BigInt.fromString("-2147483649").toI32().toString(),
    Bytes.fromHexString("0xffffffff00").toI32().toString(),
    Bytes.fromHexString("0xffffffffffffffff00").toI64().toString(),
    overflows(() => { BigInt.fromString("4294967296").toI32(); }),
    overflows(() => { BigInt.fromString("-4294967297").toI32(); }),
    overflows(() => { BigInt.fromString("18446744073709551616").toI64(); }),
  ];
  let entity = new Entity();
  entity.setI32("maxMembers", event.parameters[0].value.toBigInt().toI32());
  entity.setString("values", values.join(","));
  store.set("Subject", "s", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("BigInt.toI32() and toI64()", () => {
  it("read the low bytes as two's complement once the rest is sign padding", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Org",
              event: "SubjectCreated",
              params: { maxMembers: 4294967295n, cap: 18446744073709551615n },
            },
          ],
        },
      },
    });
    t.expect(await indexer.Subject.getAll()).toEqual([
      {
        id: "s",
        maxMembers: -1,
        values: "-1,-2147483648,0,2147483647,-1,-1,overflow,overflow,overflow",
      },
    ]);
  });
});
`,
)
