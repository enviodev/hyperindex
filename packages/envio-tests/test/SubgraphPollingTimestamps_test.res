// A polling block handler every 1,600 blocks — Notional's — asks for blocks
// close enough to merge, and merged into one range they made one HyperSync scan
// over the whole batch, paged one response at a time: 38 s per timestamp over
// Notional's 3.2M blocks. A merged range is now capped and fetched in parallel.
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
      startBlock: 18600000
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
        - event: Tick(uint256)
          handler: handleTick
      blockHandlers:
        - handler: handleBlock
          filter:
            kind: polling
            every: 1600
      file: ./src/clock.ts
`,
  ~schema=`
type Tick @entity {
  id: ID!
  timestamp: BigInt!
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
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleTick(event: any): void {}

export function handleBlock(block: any): void {
  const tick = new Entity();
  tick.setBigInt("timestamp", block.timestamp);
  store.set("Tick", block.number.toString(), tick);
}
`,
    ),
  ]),
  ~test=`
import { beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";

const g = globalThis as any;

beforeAll(() => {
  const realFetch = g.fetch;
  g.widestTimestampQuery = 0;
  g.fetch = (input: any, init: any) => {
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    if (String(input).includes("hypersync.xyz") && body?.include_all_blocks) {
      g.widestTimestampQuery = Math.max(g.widestTimestampQuery, body.to_block - body.from_block);
    }
    return realFetch(input, init);
  };
});

describe("a sparse block handler", () => {
  it("splits a long run of nearby blocks into bounded queries", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { startBlock: 18_600_000, endBlock: 18_700_000 } },
    });

    const ticks = await indexer.Tick.getAll();
    t.expect({ ticks: ticks.length, widestTimestampQuery: g.widestTimestampQuery <= 20_001 }).toEqual({
      ticks: 63,
      widestTimestampQuery: true,
    });
  });
});
`,
)
