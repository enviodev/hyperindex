// graph-node's aggregation example (graphprotocol/common-subgraphs
// aggregation-example) makes its timeseries rows with new Block("auto"):
// graph-node replaces a timeseries entity's id whatever the mapping set
// (runtime/wasm/src/host_exports.rs store_set), and graph-cli before Int8
// constructors typed the id as a string (Int8 ids arrived in 0.97.0).
let manifest = `
specVersion: 1.1.0
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
        - Block
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: Trigger(uint16)
          handler: handleTrigger
      file: ./src/mapping.ts
`

let schema = `
type Block @entity(timeseries: true) {
  id: Int8!
  timestamp: Timestamp!
  number: Int!
}

type Stats @aggregation(intervals: ["hour"], source: "Block") {
  id: Int8!
  timestamp: Timestamp!
  count: Int8! @aggregate(fn: "count")
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
    (
      "package.json",
      `{"name":"aggregation-example","devDependencies":{"@graphprotocol/graph-cli":"0.68.0","@graphprotocol/graph-ts":"0.33.0"}}`,
    ),
    ("generated/.gitkeep", ""),
    (
      "src/mapping.ts",
      `
import { Trigger } from "../generated/Contract/Contract";
import { Block } from "../generated/schema";

export function handleTrigger(event: Trigger): void {
  let block = new Block("auto");
  block.number = event.block.number.toI32();
  block.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a timeseries entity made with the id auto", () => {
  it("is saved under a generated id", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Contract", event: "Trigger", params: { x: 1n }, block: { number: 5, timestamp: 1700000000 } }] } },
    });
    t.expect((await indexer.Block.getAll()).map((row: any) => [typeof row.id, row.number])).toEqual([["string", 5]]);
  });
});
`,
)
