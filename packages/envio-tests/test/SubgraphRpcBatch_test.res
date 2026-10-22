// Contract calls the same batch makes at once travel as JSON-RPC batch
// requests: one HTTP round trip answers many. Each call keeps its own answer —
// a revert stays that call's revert — and an endpoint that limits or refuses
// batches still gets every call answered.
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
  value: BigInt
  reverted: Boolean!
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
  try_slot(index: BigInt): any {
    return this.tryCall("slot", "slot(uint256):(uint256)", [
      ethereum.Value.fromUnsignedBigInt(index),
    ]);
  }
}

export function handlePing(event: any): void {
  let nonce: BigInt = event.params.nonce;
  let result = Token.bind(event.address).try_slot(nonce);
  let slot = new Entity();
  slot.setString("id", nonce.toString());
  if (!result.reverted) slot.setBigInt("value", result.value[0].toBigInt());
  slot.setBoolean("reverted", result.reverted);
  store.set("Slot", nonce.toString(), slot);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const EVENTS = 40;

// How the endpoint treats a JSON-RPC batch.
let mode: "batches" | "atMost3" | "noBatches" = "batches";
let httpRequests = 0;
let calls = 0;

// slot(n) answers 3n; slot(7) reverts.
function answer(request: any) {
  calls++;
  const n = BigInt("0x" + request.params[0].data.slice(10));
  if (n === 7n) return { jsonrpc: "2.0", id: request.id, error: { code: 3, message: "execution reverted", data: "0x" } };
  return { jsonrpc: "2.0", id: request.id, result: "0x" + (3n * n).toString(16).padStart(64, "0") };
}

let server: Server;
beforeAll(async () => {
  server = createServer((req, res) => {
    httpRequests++;
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const parsed = JSON.parse(body);
      setTimeout(() => {
        if (!Array.isArray(parsed)) return res.end(JSON.stringify(answer(parsed)));
        if (mode === "noBatches") {
          return res.end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32600, message: "Invalid Request" } }));
        }
        if (mode === "atMost3" && parsed.length > 3) {
          return res.end(
            JSON.stringify(
              parsed.map((item: any) => ({
                jsonrpc: "2.0",
                id: item.id,
                error: { code: 31, message: "Batch of more than 3 requests are not allowed on free plan" },
              })),
            ),
          );
        }
        // Answered out of order: items are matched by id.
        res.end(JSON.stringify(parsed.map(answer).reverse()));
      }, 10);
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

const expected = Array.from({ length: EVENTS }, (_, index) => ({
  id: String(index),
  value: index === 7 ? null : 3n * BigInt(index),
  reverted: index === 7,
})).sort((a, b) => (a.id < b.id ? -1 : 1));

async function run() {
  httpRequests = 0;
  calls = 0;
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
  return (await indexer.Slot.getAll())
    .map((slot: any) => ({ id: slot.id, value: slot.value, reverted: slot.reverted }))
    .sort((a: any, b: any) => (a.id < b.id ? -1 : 1));
}

describe("contract calls made together", () => {
  it("are sent as JSON-RPC batches, each call keeping its own answer", async (t) => {
    mode = "batches";
    const slots = await run();
    t.expect({ slots, fewerRequestsThanCalls: httpRequests * 4 <= calls }).toEqual({
      slots: expected,
      fewerRequestsThanCalls: true,
    });
  });

  it("are all answered by an endpoint that limits a batch's size", async (t) => {
    mode = "atMost3";
    t.expect(await run()).toEqual(expected);
  });

  it("are all answered by an endpoint that takes no batches", async (t) => {
    mode = "noBatches";
    t.expect(await run()).toEqual(expected);
  });
});
`,
)
