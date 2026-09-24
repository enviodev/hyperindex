// Preload runs every handler of a batch at once, and each one's contract call
// with it. The RPC endpoint sees a bounded number of them at a time rather
// than one connection per call.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:8604")]),
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

const SLOT_RESULT = "0x000000000000000000000000000000000000000000000000000000000000002a";
const EVENTS = 64;

let server: Server;
let inFlight = 0;
let peak = 0;

beforeAll(async () => {
  server = createServer((req, res) => {
    inFlight++;
    peak = Math.max(peak, inFlight);
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      setTimeout(() => {
        inFlight--;
        res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: SLOT_RESULT }));
      }, 20);
    });
  });
  await new Promise<void>((resolve) => server.listen(8604, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("contract calls from a batch", () => {
  it("reach the RPC endpoint a bounded number at a time", async (t) => {
    const indexer = createTestIndexer();

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

    t.expect({ slots: (await indexer.Slot.getAll()).length, peak }).toEqual({
      slots: EVENTS,
      peak: 16,
    });
  });
});
`,
)
