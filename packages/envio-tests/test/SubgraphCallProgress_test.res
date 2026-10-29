// A batch is written only once every contract call its handlers make is in,
// and a call-heavy backfill's first batch waits minutes on thousands of them
// with nothing to show, which reads as a hang. While calls
// are outstanding, how many were answered is now logged now and then.
let port = FreePort.pick()

let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", `http://127.0.0.1:${port}`)]),
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
  let symbol = symbolOf(event.address);
  Pair.create(event.params.pair);
  let entity = new Entity();
  entity.setString("symbol", symbol);
  store.set("Pair", event.params.pair.toHexString(), entity);
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
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";
import { onLog } from "envio/src/subgraph/log.ts";

const lines: string[] = [];
let stopLogging: () => void;

const factory = "0x1111111111111111111111111111111111111111" as const;
const pair = "0x2222222222222222222222222222222222222222" as const;
const other = "0x3333333333333333333333333333333333333333" as const;

const SYMBOL_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000020" +
  "0000000000000000000000000000000000000000000000000000000000000003" +
  "4142430000000000000000000000000000000000000000000000000000000000";

let server: Server;
let ethCalls = 0;

beforeAll(async () => {
  process.env.ENVIO_SUBGRAPH_PROGRESS_LOG_MS = "50";
  stopLogging = onLog((level, message) => {
    lines.push(message);
  });
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      if (request.method === "eth_call") ethCalls++;
      setTimeout(() => res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: request.id,
          result: request.method === "eth_call" ? SYMBOL_RESULT : "0x1",
        }),
      ), request.method === "eth_call" ? 150 : 0);
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));
});

afterAll(async () => {
  stopLogging();
  delete process.env.ENVIO_SUBGRAPH_PROGRESS_LOG_MS;
  await new Promise((resolve) => server.close(resolve));
});

describe("contract calls a batch waits on", () => {
  it("are reported while they're outstanding", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Factory", event: "PairCreated", params: { pair }, srcAddress: factory, block: { number: 10 } },
            { contract: "Pair", event: "Sync", params: { reserve: 1n }, srcAddress: pair, block: { number: 20 } },
          ],
        },
      },
    });
    t.expect(lines.some((line) => /contract calls answered in the last 50ms, [0-9]+ waiting/.test(line))).toBe(true);
  });
});
`,
)
