// Block handlers run where graph-node runs them: a polling one every `every`
// blocks from the data source's start block, a `once` one at that block alone.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Clock
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Clock
      startBlock: 1
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Tick
      abis:
        - name: Clock
          file: ./abis/Clock.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      blockHandlers:
        - handler: handleBlock
          filter:
            kind: polling
            every: 3
        - handler: handleOnce
          filter:
            kind: once
      file: ./src/clock.ts
`,
  ~schema=`
type Tick @entity {
  id: ID!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Clock.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/clock.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handlePing(event: any): void {}

export function handleBlock(block: any): void {
  store.set("Tick", block.number.toString(), new Entity());
}

export function handleOnce(block: any): void {
  store.set("Tick", "once-" + block.number.toString(), new Entity());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("block handlers", () => {
  it("run every N blocks, or once, from the start block", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 7,
          simulate: [{ contract: "Clock", event: "Ping", params: { nonce: 1n }, block: { number: 7 } }],
        },
      },
    });

    const ids = (await indexer.Tick.getAll()).map((tick) => tick.id);
    t.expect(ids.sort()).toEqual(["1", "4", "7", "once-1"]);
  });
});
`,
)
