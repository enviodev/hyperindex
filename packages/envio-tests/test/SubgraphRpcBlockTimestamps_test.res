// On a chain HyperSync doesn't serve (BlockDAG, evm-1404), a block handler's
// `block.timestamp` comes from ENVIO_SUBGRAPH_RPC: the handler selects it, so
// the chain's RPC source reads the handler's blocks with its logs, and the
// subgraph runtime asks for none of them itself.
let port = FreePort.pick()

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${port}`)]),
  ~manifest=`
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Clock
    network: evm-1404
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Clock
      startBlock: 100
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
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const g = globalThis as any;
const hex = (n: number) => "0x" + n.toString(16);
const ZERO32 = "0x" + "00".repeat(32);

let server: Server;
let blockRequests = 0;
let hypersyncRequests = 0;

const blockOf = (number: number) => ({
  number: hex(number),
  hash: "0x" + number.toString(16).padStart(64, "0"),
  parentHash: "0x" + (number - 1).toString(16).padStart(64, "0"),
  timestamp: hex(1_700_000_000 + number),
  nonce: "0x0000000000000000",
  difficulty: "0x0",
  gasLimit: "0x1c9c380",
  gasUsed: "0x0",
  miner: "0x0000000000000000000000000000000000000000",
  extraData: "0x",
  logsBloom: "0x" + "00".repeat(256),
  sha3Uncles: ZERO32,
  stateRoot: ZERO32,
  transactionsRoot: ZERO32,
  receiptsRoot: ZERO32,
  size: "0x220",
  transactions: [],
  uncles: [],
});

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const parsed = JSON.parse(body);
      const answer = (request: any) => {
        switch (request.method) {
          case "eth_blockNumber":
            return hex(200);
          case "eth_getLogs":
            return [];
          case "eth_getBlockByNumber":
            blockRequests++;
            return blockOf(Number(request.params[0]));
          default:
            return hex(1404);
        }
      };
      const reply = (request: any) => ({ jsonrpc: "2.0", id: request.id, result: answer(request) });
      res.end(JSON.stringify(Array.isArray(parsed) ? parsed.map(reply) : reply(parsed)));
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));

  // HyperSync doesn't serve chain 1404. Where a firewall drops the connection
  // instead of refusing it, a request to its host answers nothing until the
  // request deadline — and the translation already knows not to ask.
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) => {
    if (!String(input).includes("hypersync.xyz")) return realFetch(input, init);
    hypersyncRequests++;
    return new Promise((_, reject) =>
      init?.signal?.addEventListener("abort", () => reject(new TypeError("fetch failed"))),
    );
  };
});

afterAll(() => server.close());

describe("block timestamps over RPC", () => {
  it("come from the chain's RPC source", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1404: { startBlock: 100, endBlock: 131 } },
    });

    const ticks = await indexer.Tick.getAll();
    t.expect({
      ticks: ticks.length,
      first: ticks.find((tick) => tick.id === "100")?.timestamp,
      last: ticks.find((tick) => tick.id === "131")?.timestamp,
      blocksRead: blockRequests >= 32,
      hypersyncRequests,
    }).toEqual({
      ticks: 32,
      first: 1_700_000_100n,
      last: 1_700_000_131n,
      blocksRead: true,
      hypersyncRequests: 0,
    });
  });
});
`,
)
