// Envio runs a register pass for every item of a response and awaits them all.
// Unbounded, a response of tens of thousands of events held that many live
// mapping runs at once (Venus on BSC: 10,000 passes, a heap past 4 GB). Passes
// now take a slot first (ENVIO_SUBGRAPH_REGISTER_CONCURRENCY), so the RPC
// endpoint and the heap see a bounded number of them, and every event still
// registers its template.
let port = FreePort.pick()

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([
    ("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${port}`),
    ("ENVIO_SUBGRAPH_REGISTER_CONCURRENCY", "4"),
  ]),
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pair
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: PairCreated(address)
          handler: handlePairCreated
      file: ./src/factory.ts
templates:
  - kind: ethereum/contract
    name: Pair
    network: mainnet
    source:
      abi: Factory
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pair
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Sync(uint256)
          handler: handleSync
      file: ./src/pair.ts
`,
  ~schema=`
type Pair @entity {
  id: ID!
  symbol: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"PairCreated","anonymous":false,"inputs":[{"name":"pair","type":"address","indexed":false}]},{"type":"event","name":"Sync","anonymous":false,"inputs":[{"name":"reserve","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/templates.ts",
      `
import { Address, DataSourceTemplate } from "@graphprotocol/graph-ts";

export class Pair extends DataSourceTemplate {
  static create(address: Address): void {
    DataSourceTemplate.create("Pair", [address.toHex()]);
  }
}
`,
    ),
    (
      "src/token.ts",
      `
import { Address, ethereum } from "@graphprotocol/graph-ts";

class Token extends ethereum.SmartContract {
  static bind(address: Address): Token {
    return new Token("Token", address);
  }
  symbol(): string {
    return this.call("symbol", "symbol():(string)", [])[0].toString();
  }
}

export function symbolOf(address: Address): string {
  return Token.bind(address).symbol();
}
`,
    ),
    (
      "src/factory.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { Pair } from "./templates";
import { symbolOf } from "./token";

export function handlePairCreated(event: any): void {
  let symbol = symbolOf(event.params.pair);
  if (symbol == "ABC") Pair.create(event.params.pair);
}
`,
    ),
    (
      "src/pair.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { symbolOf } from "./token";

export function handleSync(event: any): void {
  let entity = new Entity();
  entity.setString("symbol", symbolOf(event.address) + ":" + event.params.reserve.toString());
  store.set("Pair", event.address.toHexString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";

process.env.ENVIO_SUBGRAPH_SKIP_PRELOAD = "1";
process.env.ENVIO_SUBGRAPH_REGISTER_CONCURRENCY = "4";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const factory = "0x1111111111111111111111111111111111111111" as const;
const SYMBOL_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000020" +
  "0000000000000000000000000000000000000000000000000000000000000003" +
  "4142430000000000000000000000000000000000000000000000000000000000";
const EVENTS = 40;

let server: Server;
let inFlight = 0;
let peak = 0;
let calls = 0;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      const isCall = request.method === "eth_call";
      if (isCall) {
        calls++;
        inFlight++;
        peak = Math.max(peak, inFlight);
      }
      setTimeout(() => {
        if (isCall) inFlight--;
        res.end(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: isCall ? SYMBOL_RESULT : "0x1" }));
      }, 15);
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});

describe("register passes of one response", () => {
  it("run a bounded number at a time and all register", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 1000,
          simulate: Array.from({ length: EVENTS }, (_, i) => ({
            contract: "Factory",
            event: "PairCreated",
            params: { pair: "0x" + (0x2000 + i).toString(16).padStart(40, "0") },
            srcAddress: factory,
            block: { number: 10 + i },
          })),
        },
      },
    });
    t.expect({ calls, bounded: peak <= 4, parallel: peak > 1 }).toEqual({
      // one symbol() per event at its pair, asked once and shared with the handler pass
      calls: EVENTS,
      bounded: true,
      parallel: true,
    });
  });
});
`,
)
