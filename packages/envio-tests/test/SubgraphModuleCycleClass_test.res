// TakoTako-xyz/takotako-subgraph: `_mapping.ts` imports its helpers, and
// `helpers.ts` imports `ProtocolData` back from `_mapping.ts` to type a
// parameter. AssemblyScript has no module evaluation order to trip over; the
// table of each exported function's first-parameter class used to read the
// class while `helpers.ts` evaluated, before `_mapping.ts` had declared it, and
// the mapping failed to load with "Cannot access 'ProtocolData' before
// initialization".
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Protocol
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Touched(uint256)
          handler: handleTouched
      file: ./src/mapping.ts
`,
  ~schema=`
type Protocol @entity {
  id: ID!
  name: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Touched","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/mapping.ts",
      `
import { ProtocolData, run } from "./_mapping";

export function handleTouched(event: any): void {
  run(new ProtocolData("tako"));
}
`,
    ),
    (
      "src/_mapping.ts",
      `
import { saveProtocol } from "./helpers";

export class ProtocolData {
  constructor(public readonly name: string) {}
}

export function run(protocolData: ProtocolData): void {
  saveProtocol(protocolData);
}
`,
    ),
    (
      "src/helpers.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";
import { ProtocolData } from "./_mapping";

export function saveProtocol(protocolData: ProtocolData): void {
  const protocol = new Entity();
  protocol.set("name", Value.fromString(protocolData.name));
  store.set("Protocol", "p1", protocol);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a parameter class imported through a module cycle", () => {
  it("loads the mapping", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Pool", event: "Touched", params: { nonce: 1n } }] },
      },
    });

    t.expect(await indexer.Protocol.getAll()).toEqual([{ id: "p1", name: "tako" }]);
  });
});
`,
)
