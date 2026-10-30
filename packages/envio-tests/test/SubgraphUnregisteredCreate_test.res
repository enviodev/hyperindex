// A template address is registered by the register pass, at fetch time; the
// handler pass's create() is a no-op. When the register pass doesn't make the
// create the handler makes — it read an entity only a handler without a
// register pass saved, threw, and was forgiven — the template's events were
// lost without a word. The handler pass now says so, once per address.
let _ = InternalTestIndexer.fromSubgraph(
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
        - event: TokenListed(address)
          handler: handleTokenListed
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
        - event: DirectPair(address)
          handler: handleDirectPair
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
type Token @entity {
  id: ID!
  symbol: String!
}

type Pair @entity {
  id: ID!
  token0: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"TokenListed","anonymous":false,"inputs":[{"name":"token","type":"address","indexed":false}]},{"type":"event","name":"PairCreated","anonymous":false,"inputs":[{"name":"token0","type":"address","indexed":false},{"name":"pair","type":"address","indexed":false}]},{"type":"event","name":"DirectPair","anonymous":false,"inputs":[{"name":"pair","type":"address","indexed":false}]},{"type":"event","name":"Sync","anonymous":false,"inputs":[{"name":"reserve","type":"uint256","indexed":false}]}]`,
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
      "src/admin.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleTokenListed(event: any): void {
  let token = new Entity();
  token.setString("symbol", "WETH");
  store.set("Token", event.params.token.toHexString(), token);
}
`,
    ),
    (
      "src/factory.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { Pair } from "./templates";

export function handlePairCreated(event: any): void {
  let token0 = store.get("Token", event.params.token0.toHexString()) as Entity;
  let pair = new Entity();
  pair.setString("token0", token0.getString("symbol"));
  store.set("Pair", event.params.pair.toHexString(), pair);
  Pair.create(event.params.pair);
}

export function handleDirectPair(event: any): void {
  let pair = new Entity();
  pair.setString("token0", "none");
  store.set("Pair", event.params.pair.toHexString(), pair);
  Pair.create(event.params.pair);
}
`,
    ),
    (
      "src/pair.ts",
      `
export function handleSync(event: any): void {}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { onLog } from "envio/src/SubgraphLog.res.mjs";

const admin = "0x1111111111111111111111111111111111111111" as const;
const factory = "0x5555555555555555555555555555555555555555" as const;
const token = "0x2222222222222222222222222222222222222222" as const;
const lost = "0x3333333333333333333333333333333333333333" as const;
const direct = "0x4444444444444444444444444444444444444444" as const;

const lines: string[] = [];
let stopLogging: () => void;

beforeAll(() => {
  stopLogging = onLog((level, message) => {
    lines.push(message);
  });
});

afterAll(() => {
  stopLogging();
});

describe("a template a handler creates and no register pass did", () => {
  it("is reported, once", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Admin", event: "TokenListed", params: { token }, srcAddress: admin, block: { number: 10 } },
            { contract: "Factory", event: "PairCreated", params: { token0: token, pair: lost }, srcAddress: factory, block: { number: 20 } },
            { contract: "Factory", event: "PairCreated", params: { token0: token, pair: lost }, srcAddress: factory, block: { number: 21 } },
            { contract: "Factory", event: "DirectPair", params: { pair: direct }, srcAddress: factory, block: { number: 22 } },
          ],
        },
      },
    });
    t.expect(lines.filter((line) => line.includes("no register pass"))).toEqual([
      'Envio Subgraph: data source "Factory" created the template "Pair" for ' + lost + " at block 20 in its handler, " +
        "but no register pass did, so the events of that Pair are not indexed. A register pass reads only what " +
        "earlier register passes saved. Please open an issue: https://github.com/enviodev/hyperindex/issues",
    ]);
  });
});
`,
)
