// Run with ENVIO_SUBGRAPH_SKIP_PRELOAD=1 (the test:replay-stress script) to see it fail without the fix: the preload pass hides the replays otherwise.
// A handler is replayed while it waits on contract calls. One that edits its
// event first (Seamless rewrites `event.parameters[2]` from the v0 shape into
// the current one) met its own edit on the next round, because every round got
// the same event object: its V0 `Mint` handler read a 6-field tuple, rewrote it
// to 5 fields, and crashed on `.treasuryFee` after the call resolved.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:4761"), ("ENVIO_SUBGRAPH_SKIP_PRELOAD", "1")]),
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
  let first = event.parameters[0].value.toBigInt().toI32();
  event.parameters[0].value = ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(99));
  let name = Token.bind(event.address).try_name();
  let probe = new Entity();
  probe.setString("name", first.toString() + ":" + name.value[0].toString());
  probe.setBoolean("reverted", name.reverted);
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
let flakyFailures = 0;

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
      // Anything else is the flaky endpoint: two transport failures, then 7.
      if (flakyFailures++ < 2) {
        res.statusCode = 503;
        return res.end("upstream unavailable");
      }
      reply(SLOT_RESULT.replace(/2a$/, "07"));
    });
  });
  await new Promise<void>((resolve) => server.listen(4761, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

describe("a handler that edits its event", () => {
  it("meets the original on every round", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Token", event: "Ping", params: { nonce: 1n } }] },
      },
    });

    t.expect(await indexer.Probe.getOrThrow("probe")).toEqual({
      id: "probe",
      name: "1:envio",
      reverted: false,
    });
  });
});
`,
)
