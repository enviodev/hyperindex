// graph-node orders a `once` handler's Start trigger ahead of everything else
// in its block (chain/ethereum/src/trigger.rs `impl Ord for EthereumTrigger`:
// "Block triggers with `EthereumBlockTriggerType::Start` always come first"),
// so an event in the start block sees what the initialization handler saved.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Vault
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Vault
      startBlock: 10
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Config
      abis:
        - name: Vault
          file: ./abis/Vault.json
      eventHandlers:
        - event: Deposited(uint256)
          handler: handleDeposited
      blockHandlers:
        - handler: handleInit
          filter:
            kind: once
      file: ./src/vault.ts
`,
  ~schema=`
type Config @entity {
  id: ID!
  deposits: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Vault.json",
      `[{"type":"event","name":"Deposited","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/vault.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleInit(block: any): void {
  let config = new Entity();
  config.setI32("deposits", 100);
  store.set("Config", "config", config);
}

export function handleDeposited(event: any): void {
  let config = store.get("Config", "config");
  let next = new Entity();
  next.setI32("deposits", config === null ? -1 : config.getI32("deposits") + 1);
  store.set("Config", "config", next);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a once handler and an event in its start block", () => {
  it("runs the once handler first", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 10,
          endBlock: 12,
          simulate: [{ contract: "Vault", event: "Deposited", params: { amount: 1n }, block: { number: 10 } }],
        },
      },
    });
    t.expect(await indexer.Config.getAll()).toEqual([{ id: "config", deposits: 101 }]);
  });
});
`,
)
