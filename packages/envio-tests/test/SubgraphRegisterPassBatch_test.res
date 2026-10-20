// A batch's register passes run concurrently, and a write reaches the
// register store only when its pass completes. So every event in Venus's first
// batch missed the Market an earlier event of the batch was still creating,
// and repeated its ~20 creation calls at its own block (retest-02). A pass that
// misses an entity an earlier in-flight pass also missed now waits for that
// pass once, and reads again.
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

// getOrCreateMarket's shape: the creation path calls the contract, then saves.
export function handlePairCreated(event: any): void {
  let market = store.get("Pair", "market");
  if (market == null) {
    market = new Entity();
    market.setString("symbol", symbolOf(event.address));
    store.set("Pair", "market", market);
  }
  Pair.create(event.params.pair);
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

// Only the register pass is measured: the handler pass's preload runs every
// handler of the batch speculatively and pays its own calls.
process.env.ENVIO_SUBGRAPH_SKIP_PRELOAD = "1";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const factory = "0x1111111111111111111111111111111111111111" as const;
const pair = "0x2222222222222222222222222222222222222222" as const;
const other = "0x3333333333333333333333333333333333333333" as const;
const third = "0x4444444444444444444444444444444444444444" as const;

const SYMBOL_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000020" +
  "0000000000000000000000000000000000000000000000000000000000000003" +
  "4142430000000000000000000000000000000000000000000000000000000000";

let server: Server;
let ethCalls = 0;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      if (request.method === "eth_call") ethCalls++;
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: request.id,
          result: request.method === "eth_call" ? SYMBOL_RESULT : "0x1",
        }),
      );
    });
  });
  await new Promise<void>((resolve) => server.listen(${port}, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});

describe("register passes of one batch", () => {
  it("create an entity once, not once per event", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Factory", event: "PairCreated", params: { pair }, srcAddress: factory, block: { number: 10 } },
            { contract: "Factory", event: "PairCreated", params: { pair: other }, srcAddress: factory, block: { number: 20 } },
            { contract: "Factory", event: "PairCreated", params: { pair: third }, srcAddress: factory, block: { number: 30 } },
          ],
        },
      },
    });
    t.expect({ pairs: await indexer.Pair.getAll(), ethCalls }).toEqual({
      pairs: [{ id: "market", symbol: "ABC" }],
      // symbol() at block 10 once, by the first event's register pass; its
      // handler reuses that answer, and the later events find the market.
      ethCalls: 1,
    });
  });
});
`,
)
