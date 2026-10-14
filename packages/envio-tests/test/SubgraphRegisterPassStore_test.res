// The register pass reruns a creating handler at fetch time against a store
// that read null for everything, which lost Aave's tokens two ways:
// - `handleReserveInitialized` loads the mapping entity an earlier event saved
//   before it calls `ATokenContract.create()`. The load came back null, the
//   mapping threw before the create, and no aToken address was ever
//   registered: every aToken event was silently skipped.
// - `handleProxyCreated` creates the template, then loads an entity and
//   throws on null. The pass already had a registration, so the throw was
//   fatal: the indexer exited.
// The pass now reads what earlier register passes wrote, and a mapping that
// throws there keeps whatever it registered before it threw.
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
        - event: Configured(uint256)
          handler: handleConfigured
        - event: ProxyCreated(address)
          handler: handleProxyCreated
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

export function handleConfigured(event: any): void {
  let config = new Entity();
  config.setI32("proxies", 0);
  store.set("Config", "1", config);
}

export function handleProxyCreated(event: any): void {
  let proxy = event.params.proxy.toHexString();
  DataSourceTemplate.create("Pool", [proxy]);
  let mapping = new Entity();
  mapping.setString("pool", proxy);
  store.set("PoolMapping", proxy, mapping);
  // Saved by a handler that creates nothing, so the register pass never saw it.
  let config = store.get("Config", "1")!;
  config.setI32("proxies", config.getI32("proxies") + 1);
  store.set("Config", "1", config);
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
  it("reads what an earlier register pass wrote, and keeps a registration made before a throw", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Provider", event: "Configured", params: { value: 1n }, srcAddress: provider, block: { number: 5 } },
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
