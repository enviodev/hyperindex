// At most 16 RPC requests are in flight; the rest queue. The per-attempt
// deadline used to run from the moment a call was asked, queue included, so a
// backlog timed out before it was ever sent, was asked again at the back of
// the queue, and was sent twice: Venus's register pass logged 46k timeouts
// for 3.3k requests actually sent. The deadline now runs once a request is
// on the wire.
let port = FreePort.pick()

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${port}`)]),
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

const word = (n: bigint) => "0x" + n.toString(16).padStart(64, "0");
let server: Server;
let sent = 0;

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
      sent++;
      const n = BigInt("0x" + (request.params[0].data as string).slice(10));
      // Each answer takes 200ms: 48 calls through 16 slots is three rounds,
      // so the last ones wait 400ms in the queue — under the deadline only if
      // the queue doesn't count.
      setTimeout(() => res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: word(n * 10n) })), 200);
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));
});

afterAll(async () => {
  delete process.env.ENVIO_SUBGRAPH_REQUEST_TIMEOUT_MS;
  delete process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS;
  server.closeAllConnections();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("a backlog of contract calls", () => {
  it("is sent once each, however long it queues", async (t) => {
    const indexer = createTestIndexer();
    const pings = Array.from({ length: 48 }, (_, i) => ({ contract: "Token", event: "Ping", params: { nonce: BigInt(i + 1) } }));
    await indexer.process({ chains: { 1: { simulate: pings } } });
    t.expect({ probes: (await indexer.Probe.getAll()).length, sent }).toEqual({ probes: 48, sent: 48 });
  });
});
`,
)
