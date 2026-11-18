// graph-node's own api-version runner test (tests/runner-tests/api-version):
// before apiVersion 0.0.8 a mapping may set a field the schema doesn't define
// (runtime/wasm/src/host_exports.rs `check_invalid_fields` only refuses it
// from 0.0.8), and the entity is stored without it.
let manifest = `
specVersion: 0.0.4
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Contract
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Contract
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - TestResult
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: Trigger(uint16)
          handler: handleTrigger
      file: ./src/mapping.ts
`

let schema = `
type TestResult @entity {
  id: ID!
  message: String!
}
`

let abi = `[{"type":"event","name":"Trigger","anonymous":false,"inputs":[{"name":"x","type":"uint16","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Contract.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Contract.json", abi),
    ("generated/.gitkeep", ""),
    (
      "src/mapping.ts",
      `
import { Trigger } from "../generated/Contract/Contract";
import { Entity, Value, store } from "@graphprotocol/graph-ts";
import { TestResult } from "../generated/schema";

export function handleTrigger(event: Trigger): void {
  let testResult = new TestResult(event.params.x.toString());
  testResult.message = "0.0.7";
  let testResultEntity = testResult as Entity;
  testResultEntity.set("invalid_field", Value.fromString("This is an invalid field"));
  store.set("TestResult", testResult.id, testResult);
  testResult.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a field the schema doesn't define, before apiVersion 0.0.8", () => {
  it("is ignored", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Contract", event: "Trigger", params: { x: 7n } }] } },
    });
    t.expect(await indexer.TestResult.getAll()).toEqual([{ id: "7", message: "0.0.7" }]);
  });
});
`,
)
