// A public endpoint answers 429 past the few requests it serves at once. Asked
// 48 at a time regardless, most of every wave is refused, and each refused
// call backs off on its own for longer and longer: the batch stalls for
// minutes. Once refused, fewer requests are sent at once, and the queue drains
// at the rate the endpoint takes.
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
        - Slot
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/token.ts
`,
  ~schema=`
type Slot @entity {
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
    let result = super.call("slot", "slot(uint256):(uint256)", [
      ethereum.Value.fromUnsignedBigInt(index),
    ]);
    return result[0].toBigInt();
  }
}

export function handlePing(event: any): void {
  let nonce: BigInt = event.params.nonce;
  let slot = new Entity();
  slot.setString("id", nonce.toString());
  slot.setBigInt("value", Token.bind(event.address).slot(nonce));
  store.set("Slot", nonce.toString(), slot);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const EVENTS = 64;
// What the endpoint serves at once; past that it answers 429.
const SERVES = 4;

let server: Server;
let inFlight = 0;
let refused = 0;

beforeAll(async () => {
  // One call per HTTP request, as against an endpoint that takes no batches.
  process.env.ENVIO_SUBGRAPH_RPC_BATCH = "1";
  process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS = "200";
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      if (inFlight >= SERVES) {
        refused++;
        res.statusCode = 429;
        return res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, error: { code: 429, message: "Too Many Requests" } }));
      }
      inFlight++;
      setTimeout(() => {
        inFlight--;
        res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: "0x" + "2a".padStart(64, "0") }));
      }, 30);
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));
});

afterAll(async () => {
  delete process.env.ENVIO_SUBGRAPH_RPC_BATCH;
  delete process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS;
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("an endpoint that refuses requests past a few at once", () => {
  it("is asked fewer at a time once it refuses", async (t) => {
    const indexer = createTestIndexer();
    const started = Date.now();

    await indexer.process({
      chains: {
        1: {
          simulate: Array.from({ length: EVENTS }, (_, index) => ({
            contract: "Token",
            event: "Ping",
            params: { nonce: BigInt(index) },
          })),
        },
      },
    });

    t.expect({
      slots: (await indexer.Slot.getAll()).length,
      fewRefused: refused <= EVENTS * 2,
      quick: Date.now() - started < 10_000,
    }).toEqual({ slots: EVENTS, fewRefused: true, quick: true });
  });
});
`,
)
