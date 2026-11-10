// Venus saves its Comptroller in a `once` block handler, and getOrCreateMarket
// reads it before it creates the VToken template. Block handlers get no
// register pass, so the read was null, the mapping threw before the create,
// and no market was ever indexed. A `once` handler now runs in register mode,
// at its block, before the first register pass of its chain.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Provider
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Events
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Config
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: ProxyCreated(address)
          handler: handleProxyCreated
      blockHandlers:
        - handler: handleInitialization
          filter:
            kind: once
      file: ./src/provider.ts
templates:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      abi: Events
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - PoolMapping
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: ReserveInitialized(address)
          handler: handleReserveInitialized
      file: ./src/pool.ts
  - kind: ethereum/contract
    name: AToken
    network: mainnet
    source:
      abi: Events
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Mint
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: Mint(uint256)
          handler: handleMint
      file: ./src/atoken.ts
`,
  ~schema=`
type Config @entity {
  id: ID!
  proxies: Int!
}
type PoolMapping @entity {
  id: ID!
  pool: String!
}
type Mint @entity {
  id: ID!
  pool: String!
  amount: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Events.json",
      `[{"type":"event","name":"Configured","anonymous":false,"inputs":[{"name":"value","type":"uint256","indexed":false}]},{"type":"event","name":"ProxyCreated","anonymous":false,"inputs":[{"name":"proxy","type":"address","indexed":false}]},{"type":"event","name":"ReserveInitialized","anonymous":false,"inputs":[{"name":"aToken","type":"address","indexed":false}]},{"type":"event","name":"Mint","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/provider.ts",
      `
import { DataSourceTemplate, Entity, store } from "@graphprotocol/graph-ts";

export function handleInitialization(block: any): void {
  let config = new Entity();
  config.setI32("proxies", 0);
  store.set("Config", "1", config);
}

export function handleProxyCreated(event: any): void {
  let proxy = event.params.proxy.toHexString();
  let config = store.get("Config", "1")!;
  config.setI32("proxies", config.getI32("proxies") + 1);
  store.set("Config", "1", config);
  DataSourceTemplate.create("Pool", [proxy]);
  let mapping = new Entity();
  mapping.setString("pool", proxy);
  store.set("PoolMapping", proxy, mapping);
}
`,
    ),
    (
      "src/pool.ts",
      `
import { DataSourceTemplate, store } from "@graphprotocol/graph-ts";

export function handleReserveInitialized(event: any): void {
  let mapping = store.get("PoolMapping", event.address.toHexString());
  if (mapping == null) throw new Error("no pool mapping for " + event.address.toHexString());
  DataSourceTemplate.create("AToken", [event.params.aToken.toHexString()]);
}
`,
    ),
    (
      "src/atoken.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleMint(event: any): void {
  let mint = new Entity();
  mint.setString("pool", event.address.toHexString());
  mint.setBigInt("amount", event.params.amount);
  store.set("Mint", event.block.number.toString(), mint);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const provider = "0x1111111111111111111111111111111111111111";
const pool = "0x2222222222222222222222222222222222222222";
const aToken = "0x3333333333333333333333333333333333333333";

describe("the register pass", () => {
  it("reads what a once block handler wrote", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Provider", event: "ProxyCreated", params: { proxy: pool }, srcAddress: provider, block: { number: 10 } },
            { contract: "Pool", event: "ReserveInitialized", params: { aToken }, srcAddress: pool, block: { number: 20 } },
            { contract: "AToken", event: "Mint", params: { amount: 7n }, srcAddress: aToken, block: { number: 30 } },
          ],
        },
      },
    });

    t.expect({
      config: await indexer.Config.getAll(),
      mints: await indexer.Mint.getAll(),
    }).toEqual({
      config: [{ id: "1", proxies: 1 }],
      mints: [{ id: "30", pool: aToken, amount: 7n }],
    });
  });
});
`,
)
