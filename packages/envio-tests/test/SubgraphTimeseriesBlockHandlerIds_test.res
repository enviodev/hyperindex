// graph-node gives a timeseries row the block in the upper 32 bits of its id
// and a sequence shared by every handler of the block below
// (graph/src/components/store/entity_cache.rs `SeqGenerator::id`), so ids rise
// in insertion order across handlers — which `first` and `last` aggregates
// order by. Each block handler run here started its sequence at the same
// value, so three block handlers saving a row in one block wrote one id.
// graph-node's ids, exactly: the block's sequence counts from 0.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.1.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: First
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Clock
      startBlock: 18600000
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Point
      abis:
        - name: Clock
          file: ./abis/Clock.json
      blockHandlers:
        - handler: handleInit
          filter:
            kind: once
        - handler: handleFirst
          filter:
            kind: polling
            every: 1000
      file: ./src/clock.ts
  - kind: ethereum/contract
    name: Second
    network: mainnet
    source:
      address: "0x2222222222222222222222222222222222222222"
      abi: Clock
      startBlock: 18600000
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Point
      abis:
        - name: Clock
          file: ./abis/Clock.json
      blockHandlers:
        - handler: handleSecond
          filter:
            kind: polling
            every: 1000
      file: ./src/clock.ts
`,
  ~schema=`
type Point @entity(timeseries: true) {
  id: Int8!
  timestamp: Timestamp!
  value: BigInt!
}

type Stats @aggregation(intervals: ["hour"], source: "Point") {
  id: Int8!
  timestamp: Timestamp!
  count: Int8! @aggregate(fn: "count")
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Clock.json",
      `[{"type":"event","name":"Tick","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/clock.ts",
      `
import { BigInt, Entity, Value, store } from "@graphprotocol/graph-ts";

function point(value: i32): void {
  let row = new Entity();
  row.set("id", Value.fromI64(0));
  row.setBigInt("value", BigInt.fromI32(value));
  store.set("Point", "0", row);
}

export function handleInit(block: any): void {
  point(1);
}
export function handleFirst(block: any): void {
  point(2);
}
export function handleSecond(block: any): void {
  point(3);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("timeseries rows saved by several block handlers of one block", () => {
  it("get distinct ids, rising in the order the handlers ran", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 18_600_000, endBlock: 18_600_000 } } });
    const rows = (await indexer.Point.getAll()).sort((a: any, b: any) => (BigInt(a.id) < BigInt(b.id) ? -1 : 1));
    const id = (sequence: number) => String((18_600_000n << 32n) + BigInt(sequence));
    t.expect(rows.map((row: any) => [row.id, row.value])).toEqual([
      [id(0), 1n],
      [id(1), 2n],
      [id(2), 3n],
    ]);
  });
});
`,
)
