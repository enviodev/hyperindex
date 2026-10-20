// A template's `once` block handler runs per instance, at the block that
// created it, and only in handler mode: the register-mode run that a data
// source's `once` handler gets ahead of its chain's register passes is for
// static sources. So a create in it registers nothing, as one in a polling
// handler doesn't, and is refused the same way.
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
export function handleStrategy(event: any): void {}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a template's once block handler that creates a contract template", () => {
  it("is refused at the create, naming the handler", async (t) => {
    const indexer = createTestIndexer();

    await t
      .expect(
        indexer.process({
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
              ],
            },
          },
        }),
      )
      .rejects.toThrow(
        '  Found in data source "Vault" → blockHandlers → "handleVaultStart", which created Strategy ' +
          "0x3333333333333333333333333333333333333333 at block 10.",
      );
  });
});
`,
)
