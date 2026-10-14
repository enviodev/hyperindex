// Dolomite's shape: an admin handler saves each Token after a contract call;
// the factory's handler, at a later block, loads its pair's Token (`as Token`)
// and only then creates the pair template. The register passes of a batch run
// concurrently, so the factory's pass read the Token while the admin's pass
// was still waiting on its call, got null, threw before the create, and the
// pair was never registered: every one of its events was lost, silently. A
// pass whose read missed while an earlier pass of its chain was still running
// now waits for those passes and runs again.
let _ = InternalTestIndexer.fromSubgraph(
  ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:4695")]),
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Admin
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
        - Token
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: MarketAdded(address)
          handler: handleMarketAdded
      file: ./src/admin.ts
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x5555555555555555555555555555555555555555"
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
        - event: PairCreated(address,address)
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
  - kind: ethereum/contract
    name: Vault
    network: mainnet
    source:
      abi: Factory
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Token
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Sync(uint256)
          handler: handleSync
      file: ./src/pair.ts
`,
  ~schema=`
type Token @entity {
  id: ID!
  symbol: String!
}

type Pair @entity {
  id: ID!
  token0: Token!
  reserve: BigInt
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"MarketAdded","anonymous":false,"inputs":[{"name":"token","type":"address","indexed":false}]},{"type":"event","name":"PairCreated","anonymous":false,"inputs":[{"name":"token0","type":"address","indexed":false},{"name":"pair","type":"address","indexed":false}]},{"type":"event","name":"Sync","anonymous":false,"inputs":[{"name":"reserve","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/types/templates.ts",
      `
import { Address, DataSourceTemplate } from "@graphprotocol/graph-ts";

export class Pair extends DataSourceTemplate {
  static create(address: Address): void {
    DataSourceTemplate.create("Pair", [address.toHex()]);
  }
}

export class Vault extends DataSourceTemplate {
  static create(address: Address): void {
    DataSourceTemplate.create("Vault", [address.toHex()]);
  }
}
`,
    ),
    (
      "src/admin.ts",
      `
import { Address, Entity, ethereum, store } from "@graphprotocol/graph-ts";
import { Vault as VaultTemplate } from "./types/templates";

class ERC20 extends ethereum.SmartContract {
  static bind(address: Address): ERC20 {
    return new ERC20("ERC20", address);
  }
  symbol(): string {
    return this.call("symbol", "symbol():(string)", [])[0].toString();
  }
}

export function handleMarketAdded(event: any): void {
  let token = new Entity();
  let symbol = ERC20.bind(event.params.token).symbol();
  token.setString("symbol", symbol);
  store.set("Token", event.params.token.toHexString(), token);
  if (symbol == "VAULT") VaultTemplate.create(event.params.token);
}
`,
    ),
    (
      "src/factory.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { Pair as PairTemplate } from "./types/templates";

export function handlePairCreated(event: any): void {
  let token0 = store.get("Token", event.params.token0.toHexString()) as Entity;
  let pair = new Entity();
  pair.setString("token0", token0.getString("id"));
  store.set("Pair", event.params.pair.toHexString(), pair);
  PairTemplate.create(event.params.pair);
}
`,
    ),
    (
      "src/pair.ts",
      `
import { store } from "@graphprotocol/graph-ts";

export function handleSync(event: any): void {
  let pair = store.get("Pair", event.address.toHexString());
  if (pair == null) return;
  pair.setBigInt("reserve", event.params.reserve);
  store.set("Pair", event.address.toHexString(), pair);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import { createTestIndexer } from "envio";

const admin = "0x1111111111111111111111111111111111111111" as const;
const factory = "0x5555555555555555555555555555555555555555" as const;
const token = "0x2222222222222222222222222222222222222222" as const;
const pair = "0x3333333333333333333333333333333333333333" as const;

const SYMBOL_RESULT =
  "0x0000000000000000000000000000000000000000000000000000000000000020" +
  "0000000000000000000000000000000000000000000000000000000000000004" +
  "5745544800000000000000000000000000000000000000000000000000000000";

let server: Server;

beforeAll(async () => {
  server = createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const request = JSON.parse(body);
      res.end(
        JSON.stringify({
          jsonrpc: "2.0",
          id: request.id,
          result: request.method === "eth_call" ? SYMBOL_RESULT : "0x1",
        }),
      );
    });
  });
  await new Promise<void>((resolve) => server.listen(4695, "127.0.0.1", resolve));
});

afterAll(async () => {
  await new Promise((resolve) => server.close(resolve));
});

describe("a register pass reading what an earlier, still running pass saves", () => {
  it("sees it, and registers the template it creates after", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Admin", event: "MarketAdded", params: { token }, srcAddress: admin, block: { number: 10 } },
            { contract: "Factory", event: "PairCreated", params: { token0: token, pair }, srcAddress: factory, block: { number: 20 } },
            { contract: "Pair", event: "Sync", params: { reserve: 7n }, srcAddress: pair, block: { number: 30 } },
          ],
        },
      },
    });
    t.expect(await indexer.Pair.getAll()).toEqual([{ id: pair, token0_id: token, reserve: 7n }]);
  });
});
`,
)
