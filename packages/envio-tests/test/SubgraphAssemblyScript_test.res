// AssemblyScript exposes its primitives as namespaces as well as types, and
// real mappings read them: Messari's subgraphs open with `i32.MAX_VALUE`.
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
        - Limits
      abis:
        - name: Probe
          file: ./abis/Probe.json
      eventHandlers:
        - event: Probe(uint256)
          handler: handleProbe
      file: ./src/probe.ts
`,
  ~schema=`
type Limits @entity {
  id: ID!
  maxI32: BigInt!
  minI32: BigInt!
  maxU8: BigInt!
  maxI64: BigInt!
  truncated: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Probe.json",
      `[{"type":"event","name":"Probe","anonymous":false,"inputs":[{"name":"kind","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/probe.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

export function handleProbe(event: any): void {
  let kind = event.params.kind.toI32();
  if (kind === 1) {
    let limits = new Entity();
    limits.setBigInt("maxI32", BigInt.fromI32(i32.MAX_VALUE));
    limits.setBigInt("minI32", BigInt.fromI32(i32.MIN_VALUE));
    limits.setBigInt("maxU8", BigInt.fromI32(u8.MAX_VALUE));
    limits.setBigInt("maxI64", BigInt.fromString(i64.MAX_VALUE.toString()));
    limits.setBigInt("truncated", BigInt.fromI32(i32(3.9)));
    store.set("Limits", "1", limits);
  } else {
    i32.SOMETHING_ELSE;
  }
}
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

const probe = (kind: bigint) => ({
  chains: {
    1: { simulate: [{ contract: "Probe" as const, event: "Probe" as const, params: { kind } }] },
  },
});

describe("AssemblyScript primitives", () => {
  it("reads their bounds and casts through them", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process(probe(1n));

    t.expect(await indexer.Limits.getOrThrow("1")).toEqual({
      id: "1",
      maxI32: 2147483647n,
      minI32: -2147483648n,
      maxU8: 255n,
      maxI64: 9223372036854775807n,
      truncated: 3n,
    });
  });

  it("refuses a member that isn't one", async () => {
    await expect(createTestIndexer().process(probe(2n))).rejects.toThrow(
      /doesn't know the graph-ts API i32.SOMETHING_ELSE/,
    );
  });
});
`,
)
