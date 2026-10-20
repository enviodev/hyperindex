// A flaky RPC is the norm on public endpoints, and envio exits on a handler
// error rather than retrying the batch. So a contract call rides out a rate
// limit, a 5xx and a request that never answers, as graph-node does, and only
// a deterministic answer — a value or a revert — reaches the mapping.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:8605")]),
  ~manifest=`
specVersion: 1.2.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/token.ts
`,
  ~schema=`
type Probe @entity {
  id: ID!
  value: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { Address, BigInt, Entity, ethereum, store } from "@graphprotocol/graph-ts";

class Token extends ethereum.SmartContract {
  static bind(address: Address): Token {
    return new Token("Token", address);
  }
  slot(index: BigInt): BigInt {
    let result = this.call("slot", "slot(uint256):(uint256)", [ethereum.Value.fromUnsignedBigInt(index)]);
    return result[0].toBigInt();
  }
}

export function handlePing(event: any): void {
  let nonce: BigInt = event.params.nonce;
  let probe = new Entity();
  probe.setBigInt("value", Token.bind(event.address).slot(nonce));
  store.set("Probe", nonce.toString(), probe);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

// slot(n) answers n * 10, after whatever the case says the endpoint does first.
const word = (n: bigint) => "0x" + n.toString(16).padStart(64, "0");
const plans = new Map<bigint, string[]>();

let server: Server;

beforeAll(async () => {
  process.env.ENVIO_SUBGRAPH_REQUEST_TIMEOUT_MS = "500";
  process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS = "20";
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      if (request.method !== "eth_call") {
        return res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: "0x1" }));
      }
      const n = BigInt("0x" + (request.params[0].data as string).slice(10));
      const next = plans.get(n)?.shift();
      if (next === "hang") return;
      if (next === "rate-limit") {
        return res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            id: request.id,
            error: { code: -32005, message: "over rate limit" },
          }),
        );
      }
      // blastapi's, with a code of its own and no "rate limit" in the words.
      if (next === "capacity") {
        return res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            id: request.id,
            error: { code: -32097, message: "Your app has exceeded its compute units per second capacity" },
          }),
        );
      }
      // A node's own failure, sent as a JSON-RPC error over a 200: dRPC and
      // Sei's public endpoint answer "Internal error" now and then, and the
      // same call answers on the next try.
      if (next === "internal") {
        return res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            id: request.id,
            error: { code: -32603, message: "Internal error" },
          }),
        );
      }
      if (next === "unavailable") {
        res.statusCode = 503;
        return res.end("upstream unavailable");
      }
      res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: word(n * 10n) }));
    });
  });
  await new Promise<void>((resolve) => server.listen(8605, "127.0.0.1", resolve));
});

afterAll(async () => {
  delete process.env.ENVIO_SUBGRAPH_REQUEST_TIMEOUT_MS;
  delete process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS;
  server.closeAllConnections();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

const ping = (nonce: bigint) => ({ contract: "Token", event: "Ping", params: { nonce } });

describe("a contract call over a flaky RPC", () => {
  it("rides out a rate limit, a 5xx and an internal error", async (t) => {
    plans.set(1n, Array(9).fill("rate-limit"));
    plans.set(2n, Array(9).fill("unavailable"));
    plans.set(4n, Array(3).fill("capacity"));
    plans.set(5n, Array(3).fill("internal"));
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [ping(1n), ping(2n), ping(4n), ping(5n)] } } });

    t.expect((await indexer.Probe.getAll()).sort((a, b) => a.id.localeCompare(b.id))).toEqual([
      { id: "1", value: 10n },
      { id: "2", value: 20n },
      { id: "4", value: 40n },
      { id: "5", value: 50n },
    ]);
  });

  it("gives up on a request that never answers and asks again", async (t) => {
    plans.set(3n, Array(5).fill("hang"));
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [ping(3n)] } } });

    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "3", value: 30n }]);
  });
});
`,
)
