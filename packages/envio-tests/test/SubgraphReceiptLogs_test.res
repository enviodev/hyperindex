// `event.receipt.logs`: every log of the event's transaction, read from
// HyperSync's logs of the block. Live against HyperSync, like
// SubgraphBlockHandler_test. Block 18,600,000's first transaction emits 19
// logs, the first two of them Transfers of 0x561c…, the last a Uniswap-style
// event of 0x2fdb….
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x561cf9121e89926c27fa1cfc78dfcc4c422937a4"
      abi: Token
      startBlock: 18600000
      endBlock: 18600000
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Seen
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
          receipt: true
      file: ./src/token.ts
`,
  ~schema=`
type Seen @entity {
  id: ID!
  count: BigInt!
  first: String!
  last: String!
  lastTopic0: String!
  lastIndex: BigInt!
  lastBlockHash: String!
  lastName: String!
  status: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Transfer","anonymous":false,"inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"value","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { BigInt, Bytes, Entity, TypedMap, store } from "@graphprotocol/graph-ts";

export function handleTransfer(event: any): void {
  const receipt = event.receipt!;
  const logs = receipt.logs;
  const last = logs[logs.length - 1];
  const seen = new Entity();
  seen.setBigInt("count", BigInt.fromI32(logs.length));
  seen.setString("first", logs[0].address.toHexString());
  seen.setString("last", last.address.toHexString());
  seen.setString("lastTopic0", last.topics[0].toHexString());
  seen.setBigInt("lastIndex", last.logIndex);
  seen.setString("lastBlockHash", last.blockHash.toHexString());
  seen.setBigInt("status", receipt.status);
  // Lido finds a log's parser by its topic0 in a TypedMap keyed by Bytes built
  // elsewhere: keys compare by value.
  const parsers = new TypedMap<Bytes, string>();
  parsers.set(Bytes.fromHexString("0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822"), "Sync");
  seen.setString("lastName", parsers.get(last.topics[0])!);
  store.set("Seen", event.logIndex.toString(), seen);
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
  g.logQueries = 0;
  g.fetch = (input: any, init: any) => {
    const body = typeof init?.body === "string" ? JSON.parse(init.body) : undefined;
    if (String(input).includes("hypersync.xyz") && body?.logs?.length === 1 && Object.keys(body.logs[0]).length === 0) {
      g.logQueries++;
    }
    return realFetch(input, init);
  };
});

describe("event.receipt.logs", () => {
  it("serves the logs of the event's transaction from one HyperSync query per block", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { startBlock: 18_600_000, endBlock: 18_600_000 } },
    });

    const seen = await Promise.all(["0", "1"].map((id) => indexer.Seen.getOrThrow(id)));
    t.expect({
      seen: seen.map(({ count, first, last, lastTopic0, lastIndex, status, lastName }) => ({
        count, first, last, lastTopic0, lastIndex, status, lastName,
      })),
      lastBlockHashIsTheBlocks: seen[0].lastBlockHash,
      // Two events of one transaction, one block: one read of its logs.
      logQueries: g.logQueries,
    }).toEqual({
      seen: [0, 1].map(() => ({
        count: 19n,
        first: "0x561cf9121e89926c27fa1cfc78dfcc4c422937a4",
        last: "0x2fdbadf3c4d5a8666bc06645b8358ab803996e28",
        lastTopic0: "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822",
        lastIndex: 18n,
        status: 1n,
        lastName: "Sync",
      })),
      lastBlockHashIsTheBlocks: "0xe04bd723e726b32b478ba9ea2cfc514c7264b7c653745ff8f950c3e78f13fbbd",
      logQueries: 1,
    });
  });
});
`,
)
