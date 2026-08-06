// A block handler's `block.timestamp`. Live against HyperSync, like
// HyperSyncClient_test: every handler invocation in a batch asks within the
// same microtask, so one range query answers all of them.
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
            every: 1
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
  g.hypersyncRequests = 0;
  g.fetch = (input: any, init: any) => {
    if (String(input).includes("hypersync.xyz")) {
      g.hypersyncRequests++;
    }
    return realFetch(input, init);
  };
});

describe("block handlers", () => {
  it("reads timestamps from one batched HyperSync query", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { startBlock: 18_600_000, endBlock: 18_600_002 } },
    });

    const ticks = await Promise.all(
      [18_600_000, 18_600_001, 18_600_002].map((block) =>
        indexer.Tick.getOrThrow(String(block)),
      ),
    );

    t.expect({
      ticks: ticks.map((tick) => [tick.id, tick.timestamp]),
      // Three blocks, one round trip — and the preload pass already had the
      // answer by the time the execute pass ran.
      hypersyncRequests: g.hypersyncRequests,
    }).toEqual({
      ticks: [
        ["18600000", 1_700_325_959n],
        ["18600001", 1_700_325_971n],
        ["18600002", 1_700_325_983n],
      ],
      hypersyncRequests: 1,
    });
  });
});
`,
)
