// The register pass reruns a handler at fetch time only to collect the
// templates it creates, and every contract call the handler makes on the way is
// made again there. A template's swap-style handler, which creates nothing, used
// to pay that for every event — Venus and Aave spent most of their RPC budget
// on it. Only the handlers whose code can reach a create get the pass now.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:4690")]),
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
  await new Promise<void>((resolve) => server.listen(4690, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});

describe("the register pass", () => {
  it("skips a handler that can't create a template, and shares one call with the ones that can", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Factory",
              event: "PairCreated",
              params: { pair },
              srcAddress: factory,
              block: { number: 10 },
            },
            {
              contract: "Factory",
              event: "PairCreated",
              params: { pair: other },
              srcAddress: factory,
              block: { number: 10 },
            },
            { contract: "Pair", event: "Sync", params: { reserve: 1n }, srcAddress: pair, block: { number: 20 } },
            { contract: "Pair", event: "Sync", params: { reserve: 2n }, srcAddress: pair, block: { number: 30 } },
          ],
        },
      },
    });

    t.expect({
      pairs: (await indexer.Pair.getAll()).sort((a, b) => a.id.localeCompare(b.id)),
      ethCalls,
    }).toEqual({
      pairs: [
        { id: pair, symbol: "ABC:2" },
        { id: other, symbol: "ABC" },
      ],
      // The factory's symbol() at block 10 once, for both register passes,
      // which run concurrently, and for both handlers, which reuse their
      // answer; then one per Sync, from the handler itself — none from a
      // register pass.
      ethCalls: 3,
    });
  });
});
`,
)
