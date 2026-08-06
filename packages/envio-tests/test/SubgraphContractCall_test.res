// Contract calls from a mapping: an envio effect over viem, evaluated at the
// event's block. A revert is data; a transport failure is a handler error.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:8599")]),
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
  name: String!
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
import { Address, Entity, ethereum, store } from "@graphprotocol/graph-ts";

// What graph codegen emits for a contract binding: a SmartContract subclass
// whose methods go through call/tryCall.
class Token extends ethereum.SmartContract {
  static bind(address: Address): Token {
    return new Token("Token", address);
  }
  try_name(): any {
    return this.tryCall("name", "name():(string)", []);
  }
  try_boom(): any {
    return this.tryCall("boom", "boom():(uint256)", []);
  }
  try_flaky(): any {
    return this.tryCall("flaky", "flaky():(uint256)", []);
  }
}

export function handlePing(event: any): void {
  let token = Token.bind(event.address);
  let nonce = event.params.nonce.toI32();

  if (nonce === 2) {
    // A transport failure must not be mistaken for a revert.
    token.try_flaky();
    return;
  }

  let name = token.try_name();
  let boom = token.try_boom();

  let probe = new Entity();
  probe.setString("name", name.reverted ? "reverted" : name.value[0].toString());
  probe.setBoolean("reverted", boom.reverted);
  store.set("Probe", "probe", probe);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

// name() -> "envio", ABI-encoded.
const NAME_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000020" +
  "0000000000000000000000000000000000000000000000000000000000000005" +
  "656e76696f000000000000000000000000000000000000000000000000000000";

const NAME_SELECTOR = "0x06fdde03";
const BOOM_SELECTOR = "0xa169ce09";

let server: Server;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      const data: string = request.params?.[0]?.data ?? "";
      const reply = (result: unknown) =>
        res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));

      if (request.method !== "eth_call") return reply("0x1");
      if (data.startsWith(NAME_SELECTOR)) return reply(NAME_RESULT);
      if (data.startsWith(BOOM_SELECTOR)) {
        return res.end(
          JSON.stringify({
            jsonrpc: "2.0",
            id: request.id,
            error: { code: 3, message: "execution reverted" },
          }),
        );
      }
      // Anything else is the flaky endpoint: a transport failure.
      res.statusCode = 503;
      res.end("upstream unavailable");
    });
  });
  await new Promise<void>((resolve) => server.listen(8599, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("contract calls", () => {
  it("returns call results and reverts as data", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Ping", params: { nonce: 1n } }] },
      },
    });

    t.expect(await indexer.Probe.getOrThrow("probe")).toEqual({
      id: "probe",
      name: "envio",
      reverted: true,
    });
  });

  it("fails the handler on a transport error instead of faking a revert", async () => {
    const indexer = createTestIndexer();

    await expect(
      indexer.process({
        chains: {
          1: { simulate: [{ contract: "Token", event: "Ping", params: { nonce: 2n } }] },
        },
      }),
    ).rejects.toThrow();
  });
});
`,
)
