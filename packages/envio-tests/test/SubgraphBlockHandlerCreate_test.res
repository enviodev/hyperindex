// centrifuge/tinlake's unfiltered block handler creates the Coordinator, Pile,
// … templates of each pool it preloads. envio registers a template's instances
// only in a register pass, and a block handler other than a `once` one gets
// none, so those instances never had their events indexed: 1 Pool of the
// deployment's 4, 0 Loans of 46, and only a warning per create. The create is
// refused where it runs, naming the handler; the `once` handler's, made in
// register mode, is not.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Block
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
        - Pool
      abis:
        - name: Events
          file: ./abis/Events.json
      blockHandlers:
        - handler: handleSetup
          filter:
            kind: once
        - handler: handleBlock
      file: ./src/block.ts
templates:
  - kind: ethereum/contract
    name: Coordinator
    network: mainnet
    source:
      abi: Events
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Pool
      abis:
        - name: Events
          file: ./abis/Events.json
      eventHandlers:
        - event: Epoch(uint256)
          handler: handleEpoch
      file: ./src/coordinator.ts
`

let abi = `[{"type":"event","name":"Epoch","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false}]}]`

let schema = `
type Pool @entity {
  id: ID!
  epochs: Int!
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
      "src/pools.ts",
      `
import { Address } from "@graphprotocol/graph-ts";
import { Coordinator as CoordinatorTemplate } from "../generated/templates";

export function createPoolHandlers(coordinator: string): void {
  CoordinatorTemplate.create(Address.fromString(coordinator));
}
`,
    ),
    (
      "src/block.ts",
      `
import { ethereum } from "@graphprotocol/graph-ts";
import { createPoolHandlers } from "./pools";

export function handleSetup(block: ethereum.Block): void {
  createPoolHandlers("0x2222222222222222222222222222222222222222");
}

export function handleBlock(block: ethereum.Block): void {
  if (block.number.toI32() == 5) createPoolHandlers("0x3333333333333333333333333333333333333333");
}
`,
    ),
    (
      "src/coordinator.ts",
      `
import { ethereum } from "@graphprotocol/graph-ts";

export function handleEpoch(event: ethereum.Event): void {}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a block handler that creates a contract template", () => {
  it("is refused at the create, naming the handler", async (t) => {
    const indexer = createTestIndexer();

    await t
      .expect(indexer.process({ chains: { 1: { startBlock: 0, endBlock: 10, simulate: [] } } }))
      .rejects.toThrow(
        "Envio Subgraph doesn't support creating contract templates from a block handler yet: envio " +
          "registers a template's instances in a register pass ahead of the handlers, and only event " +
          "handlers, call handlers and a data source's \`once\` block handlers get one, so the instances a " +
          "block handler creates would never have their events indexed.\\n" +
          '  Found in data source "Block" → blockHandlers → "handleBlock", which created Coordinator ' +
          "0x3333333333333333333333333333333333333333 at block 5.",
      );
  });
});
`,
)
