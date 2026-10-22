// `block.hash` and `block.parentHash` in a block handler. Live against
// HyperSync, like SubgraphBlockHandler_test: the header is fetched in the same
// batched query for every block of a batch, only from below the chain's reorg
// window. A handler that reads just the timestamp keeps
// its narrow query and doesn't hold its chain back.
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
        - Header
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
type Header @entity {
  id: ID!
  hash: Bytes!
  parentHash: Bytes!
  author: Bytes!
  gasUsed: BigInt!
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
  const header = new Entity();
  header.setBytes("hash", block.hash);
  header.setBytes("parentHash", block.parentHash);
  header.setBytes("author", block.author);
  header.setBigInt("gasUsed", block.gasUsed);
  header.setBigInt("timestamp", block.timestamp);
  store.set("Header", block.number.toString(), header);
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
  g.headerQueries = 0;
  g.fetch = (input: any, init: any) => {
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    if (String(input).includes("hypersync.xyz") && body?.field_selection?.block?.includes("parent_hash")) {
      g.headerQueries++;
    }
    return realFetch(input, init);
  };
});

describe("block.hash in a block handler", () => {
  it("reads the header of every block from one batched HyperSync query", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { startBlock: 18_600_000, endBlock: 18_600_002 } },
    });

    const first = await indexer.Header.getOrThrow("18600000");
    const second = await indexer.Header.getOrThrow("18600001");
    t.expect({
      first: {
        hash: Buffer.from(first.hash).toString("hex"),
        parentHash: Buffer.from(first.parentHash).toString("hex"),
        author: Buffer.from(first.author).toString("hex"),
        gasUsed: first.gasUsed,
        timestamp: first.timestamp,
      },
      // A chain of blocks: each one's parent is the previous one's hash.
      linked: Buffer.from(second.parentHash).toString("hex") === Buffer.from(first.hash).toString("hex"),
      headerQueries: g.headerQueries,
    }).toEqual({
      first: {
        hash: "e04bd723e726b32b478ba9ea2cfc514c7264b7c653745ff8f950c3e78f13fbbd",
        parentHash: "ebacac40054e83deb9328df39aed2fa55c9ca2b70e0ed1e581ecce19775abe73",
        author: "1f9090aae28b8a3dceadf281b0f12828e676c326",
        gasUsed: 0x010e1630n,
        timestamp: 0x6558ea47n,
      },
      linked: true,
      headerQueries: 1,
    });
  });
});
`,
)
