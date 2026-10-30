// A template's `once` block handler runs for each instance at the block that
// created it: the instance's start block (chain/ethereum/src/data_source.rs,
// `from_template_info`: `start_block: creation_block`), matched by its `Start`
// trigger when graph-node reprocesses that block for the new data source. What
// it creates is indexed from there. sushi's clipper-rfq creates a PriceOracle
// from the `once` handler of each PriceOracleProxy a Blade pool registers.
// That create was refused: the handler had no register pass.
let manifest = `
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
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
        - Probe
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: Deployed(address)
          handler: handleDeployed
      file: ./src/factory.ts
templates:
  - kind: ethereum/contract
    name: Vault
    network: mainnet
    source:
      abi: Events
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Events
          file: ./abis/Events.json
      blockHandlers:
        - handler: handleVaultStart
          filter:
            kind: once
      file: ./src/vault.ts
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
        - Probe
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: Deployed(address)
          handler: handleStrategy
      file: ./src/strategy.ts
`

let abi = `[{"type":"event","name":"Deployed","anonymous":false,"inputs":[{"name":"target","type":"address","indexed":false}]}]`

let schema = `
type Probe @entity {
  id: ID!
}
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("./abis/Events.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Events.json", abi),
    (
      "src/factory.ts",
      `
import { Vault } from "../generated/templates";

export function handleDeployed(event: any): void {
  Vault.create(event.params.target);
}
`,
    ),
    (
      "src/vault.ts",
      `
import { Address, ethereum } from "@graphprotocol/graph-ts";
import { Strategy } from "../generated/templates";

export function handleVaultStart(block: ethereum.Block): void {
  Strategy.create(Address.fromString("0x3333333333333333333333333333333333333333"));
}
`,
    ),
    (
      "src/strategy.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleStrategy(event: any): void {
  store.set("Probe", event.block.number.toString(), new Entity());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const strategyEvent = (block) => ({
  contract: "Strategy",
  event: "Deployed",
  params: { target: "0x0000000000000000000000000000000000000000" },
  srcAddress: "0x3333333333333333333333333333333333333333",
  block: { number: block },
});

describe("a template's once block handler that creates a contract template", () => {
  it("indexes what it creates from the block that created the template's instance", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 12,
          simulate: [
            {
              contract: "Factory",
              event: "Deployed",
              params: { target: "0x2222222222222222222222222222222222222222" },
              block: { number: 10 },
            },
            strategyEvent(10),
            strategyEvent(12),
          ],
        },
      },
    });
    t.expect(await indexer.Probe.getAll()).toEqual([{ id: "10" }, { id: "12" }]);
  });
});
`,
)
