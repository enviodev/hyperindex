// graph-node's own int8 and timestamp integration tests
// (tests/integration-tests/{int8,timestamp}): an Int8 field holds
// i64.MAX_VALUE and a Timestamp field microseconds, both read back through the
// generated getters unchanged. The timestamp here is whole milliseconds: a JS
// date drops graph-node's sub-millisecond digits (docs/subgraph-compat.md §2).
let manifest = `
specVersion: 1.0.0
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
      apiVersion: 0.0.8
      language: wasm/assemblyscript
      entities:
        - Big
        - Moment
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: Trigger(uint16)
          handler: handleTrigger
      file: ./src/mapping.ts
`

let schema = `
type Big @entity {
  id: ID!
  value: Int8!
}

type Moment @entity {
  id: ID!
  value: Timestamp!
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
import { Big, Moment } from "../generated/schema";

export function handleTrigger(event: Trigger): void {
  let big = new Big("0");
  big.value = i64.MAX_VALUE;
  big.save();
  big = <Big>Big.load("0");
  assert(big.value == i64.MAX_VALUE, "maybe invalid value");

  let moment = new Moment("0");
  moment.value = 1710837304040000;
  moment.save();
  moment = <Moment>Moment.load("0");
  assert(moment.value == 1710837304040000, "maybe invalid value");
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Int8 and Timestamp fields", () => {
  it("round-trip i64.MAX_VALUE and microseconds", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Contract", event: "Trigger", params: { x: 1n } }] } },
    });
    t.expect({ big: await indexer.Big.getAll(), moment: await indexer.Moment.getAll() }).toEqual({
      big: [{ id: "0", value: 9223372036854775807n }],
      moment: [{ id: "0", value: new Date(1710837304040) }],
    });
  });
});
`,
)
