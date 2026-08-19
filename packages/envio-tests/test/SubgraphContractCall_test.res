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
import { Address, BigInt, Entity, ethereum, store } from "@graphprotocol/graph-ts";

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
  try_oddName(): any {
    return this.tryCall("oddName", "oddName():(string)", []);
  }
  // What graph codegen emits for a function taking an integer: the argument
  // goes through the ethereum-specific Value factories.
  try_slot(index: BigInt): any {
    return this.tryCall("slot", "slot(uint256):(uint256)", [
      ethereum.Value.fromUnsignedBigInt(index),
    ]);
  }
  // What graph codegen emits for a struct/tuple return.
  getMarginRatio(): any {
    let result = this.call("getMarginRatio", "getMarginRatio():((uint256))", []);
    return result[0].toTuple();
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

  if (nonce === 4) {
    let slot = token.try_slot(BigInt.fromI32(7));
    let probe = new Entity();
    probe.setString("name", slot.reverted ? "reverted" : slot.value[0].toString());
    probe.setBoolean("reverted", slot.reverted);
    store.set("Probe", "slot", probe);
    return;
  }

  if (nonce === 3) {
    let odd = token.try_oddName();
    let probe = new Entity();
    probe.setString("name", odd.reverted ? "reverted" : odd.value[0].toString());
    probe.setBoolean("reverted", odd.reverted);
    store.set("Probe", "odd", probe);
    return;
  }

  if (nonce === 5) {
    let fields = token.getMarginRatio();
    let probe = new Entity();
    probe.setString("name", fields[0].toBigInt().toString());
    probe.setBoolean("reverted", false);
    store.set("Probe", "ratio", probe);
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
const ODD_NAME_SELECTOR = "0x4d9386ad";
const SLOT_SELECTOR = "0xb2025e4f";
const SLOT_RESULT =
  "0x000000000000000000000000000000000000000000000000000000000000002a";
const RATIO_SELECTOR = "0x4f3c1542";
const RATIO_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000064";

// A bytes32 name from a pre-ERC20 token, which can't be decoded as the string
// the signature declares.
const ODD_NAME_RESULT =
  "0x656e76696f000000000000000000000000000000000000000000000000000000";

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
      if (data.startsWith(ODD_NAME_SELECTOR)) return reply(ODD_NAME_RESULT);
      if (data.startsWith(SLOT_SELECTOR)) return reply(SLOT_RESULT);
      if (data.startsWith(RATIO_SELECTOR)) return reply(RATIO_RESULT);
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

  it("reports output it cannot decode as a reverted call", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Ping", params: { nonce: 3n } }] },
      },
    });

    t.expect(await indexer.Probe.getOrThrow("odd")).toEqual({
      id: "odd",
      name: "reverted",
      reverted: true,
    });
  });

  it("unwraps a tuple return the way graph codegen does", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Ping", params: { nonce: 5n } }] },
      },
    });

    t.expect(await indexer.Probe.getOrThrow("ratio")).toEqual({
      id: "ratio",
      name: "100",
      reverted: false,
    });
  });

  it("passes an integer argument through the ethereum Value factories", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Ping", params: { nonce: 4n } }] },
      },
    });

    t.expect(await indexer.Probe.getOrThrow("slot")).toEqual({
      id: "slot",
      name: "42",
      reverted: false,
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
