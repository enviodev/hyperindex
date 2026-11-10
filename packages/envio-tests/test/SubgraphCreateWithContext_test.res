// DexStrategy-style factories create a template with a context
// (`createWithContext`) that the template's handlers read back through
// `dataSource.context()`. The created address is all envio keeps of a data
// source, so the context is kept by chain, template and address. Refused as
// "nowhere to keep it" before (yieldyak).
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
        - Mint
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: ProxyCreated(address)
          handler: handleProxyCreated
      file: ./src/provider.ts
templates:
  - kind: ethereum/contract
    name: Strategy
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
      file: ./src/strategy.ts
`,
  ~schema=`
type Mint @entity {
  id: ID!
  symbol: String!
  decimals: Int!
  v4: Boolean!
  cap: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Events.json",
      `[{"type":"event","name":"ProxyCreated","anonymous":false,"inputs":[{"name":"proxy","type":"address","indexed":false}]},{"type":"event","name":"Mint","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/provider.ts",
      `
import { BigInt, DataSourceContext, DataSourceTemplate } from "@graphprotocol/graph-ts";

export function handleProxyCreated(event: any): void {
  let context = new DataSourceContext();
  context.setString("symbol", "AVAX");
  context.setI32("decimals", 18);
  context.setBoolean("v4", true);
  context.setBigInt("cap", BigInt.fromI32(5000));
  DataSourceTemplate.createWithContext("Strategy", [event.params.proxy.toHexString()], context);
}
`,
    ),
    (
      "src/strategy.ts",
      `
import { dataSource, Entity, store } from "@graphprotocol/graph-ts";

export function handleMint(event: any): void {
  let context = dataSource.context();
  let mint = new Entity();
  mint.setString("symbol", context.getString("symbol"));
  mint.setI32("decimals", context.getI32("decimals"));
  mint.setBoolean("v4", context.getBoolean("v4"));
  mint.setBigInt("cap", context.getBigInt("cap"));
  store.set("Mint", event.block.number.toString(), mint);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const provider = "0x1111111111111111111111111111111111111111";
const strategy = "0x2222222222222222222222222222222222222222";

describe("a template created with a context", () => {
  it("serves that context to its handlers", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Provider", event: "ProxyCreated", params: { proxy: strategy }, srcAddress: provider, block: { number: 10 } },
            { contract: "Strategy", event: "Mint", params: { amount: 7n }, srcAddress: strategy, block: { number: 30 } },
          ],
        },
      },
    });

    t.expect(await indexer.Mint.getAll()).toEqual([
      { id: "30", symbol: "AVAX", decimals: 18, v4: true, cap: 5000n },
    ]);
  });
});
`,
)
