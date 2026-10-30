// yieldyak/subgraph-strategies: the only data source has nothing but a `once`
// block handler, which creates every strategy template; graph-node indexes the
// strategies' events from that block on. The handler's create was registered
// only from the first register pass of an event that creates a template, at
// that event's block, and this chain has none: the run synced with no strategy
// event indexed. A `once` trigger matches only at the data source's start block
// (chain/ethereum/src/data_source.rs, `handler_for_block`:
// `BlockHandlerFilter::Once => block == self.start_block`), and the data source
// it creates gets that block's triggers after the rest of the block.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Strategy
      startBlock: 10
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Deposit
      abis:
        - name: Strategy
          file: ./abis/Strategy.json
      blockHandlers:
        - handler: handleOnce
          filter:
            kind: once
      file: ./src/registry.ts
templates:
  - kind: ethereum/contract
    name: Strategy
    network: mainnet
    source:
      abi: Strategy
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Deposit
      abis:
        - name: Strategy
          file: ./abis/Strategy.json
      eventHandlers:
        - event: Deposited(uint256)
          handler: handleDeposited
      file: ./src/registry.ts
`,
  ~schema=`
type Deposit @entity {
  id: ID!
  amount: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Strategy.json",
      `[{"type":"event","name":"Deposited","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Address, DataSourceTemplate, Entity, store } from "@graphprotocol/graph-ts";

export function handleOnce(block: any): void {
  DataSourceTemplate.create("Strategy", ["0x2222222222222222222222222222222222222222"]);
}

export function handleDeposited(event: any): void {
  let deposit = new Entity();
  deposit.setBigInt("amount", event.params.amount);
  store.set("Deposit", event.block.number.toString(), deposit);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const deposit = (amount, block) => ({
  contract: "Strategy",
  event: "Deposited",
  params: { amount },
  srcAddress: "0x2222222222222222222222222222222222222222",
  block: { number: block },
});

describe("a template created by the chain's only once handler", () => {
  it("has its events indexed from the handler's block on", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 10,
          endBlock: 30,
          simulate: [deposit(4n, 10), deposit(5n, 20)],
        },
      },
    });
    t.expect(await indexer.Deposit.getAll()).toEqual([
      { id: "10", amount: 4n },
      { id: "20", amount: 5n },
    ]);
  });
});
`,
)
