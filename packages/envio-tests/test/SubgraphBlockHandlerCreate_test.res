// centrifuge/tinlake's unfiltered block handler creates the Coordinator, Pile,
// … templates of each pool it preloads, and graph-node indexes their events from
// that block on: 4 Pools and 46 Loans on the live deployment, 1 and 0 when a
// block handler's create registered nothing. graph-node runs a data source
// created in block N for the triggers of N that match it, after the rest of the
// block (core/src/subgraph/runner/mod.rs, `process_dynamic_data_sources`:
// "Reprocess the triggers from this block that match the new data sources"),
// and from N + 1 on as any other. So the instance's event logged in its creation
// block runs after the handler that created it. (An event before that block
// can't be simulated: it never reaches a handler, which simulate refuses.)
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
      startBlock: 1
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
  createdAt: Int!
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
import { Address, Entity, Value, store } from "@graphprotocol/graph-ts";
import { Coordinator as CoordinatorTemplate } from "../generated/templates";

export function createPoolHandlers(coordinator: string, createdAt: i32): void {
  CoordinatorTemplate.create(Address.fromString(coordinator));
  let pool = new Entity();
  pool.set("id", Value.fromString(coordinator));
  pool.set("createdAt", Value.fromI32(createdAt));
  pool.set("epochs", Value.fromI32(0));
  store.set("Pool", coordinator, pool);
}
`,
    ),
    (
      "src/block.ts",
      `
import { ethereum } from "@graphprotocol/graph-ts";
import { createPoolHandlers } from "./pools";

export function handleSetup(block: ethereum.Block): void {
  createPoolHandlers("0x2222222222222222222222222222222222222222", block.number.toI32());
}

export function handleBlock(block: ethereum.Block): void {
  if (block.number.toI32() == 5) createPoolHandlers("0x3333333333333333333333333333333333333333", 5);
}
`,
    ),
    (
      "src/coordinator.ts",
      `
import { Entity, Value, ethereum, store } from "@graphprotocol/graph-ts";

// A Pool its creator hasn't saved yet reads createdAt -1.
export function handleEpoch(event: ethereum.Event): void {
  let id = event.address.toHexString();
  let pool = store.get("Pool", id);
  if (pool == null) {
    pool = new Entity();
    pool.set("id", Value.fromString(id));
    pool.set("createdAt", Value.fromI32(-1));
    pool.set("epochs", Value.fromI32(0));
  }
  pool.set("epochs", Value.fromI32(pool.getI32("epochs") + 1));
  store.set("Pool", id, pool);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const epoch = (address, block, logIndex = 0) => ({
  contract: "Coordinator",
  event: "Epoch",
  params: { id: 1n },
  srcAddress: address,
  block: { number: block },
  logIndex,
});

describe("a block handler that creates a contract template", () => {
  it("indexes the instance's events from its creation block on, after its creator", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 10,
          simulate: [
            epoch("0x2222222222222222222222222222222222222222", 1),
            epoch("0x2222222222222222222222222222222222222222", 3),
            epoch("0x3333333333333333333333333333333333333333", 5),
            epoch("0x3333333333333333333333333333333333333333", 8),
          ],
        },
      },
    });
    t.expect(await indexer.Pool.getAll()).toEqual([
      { id: "0x2222222222222222222222222222222222222222", createdAt: 1, epochs: 2 },
      { id: "0x3333333333333333333333333333333333333333", createdAt: 5, epochs: 2 },
    ]);
  });

  it("keeps the instance registered when indexing resumes past its creation block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 6,
          simulate: [epoch("0x3333333333333333333333333333333333333333", 5)],
        },
      },
    });
    await indexer.process({
      chains: {
        1: {
          endBlock: 12,
          simulate: [epoch("0x3333333333333333333333333333333333333333", 9)],
        },
      },
    });
    t.expect(await indexer.Pool.getAll()).toEqual([
      { id: "0x2222222222222222222222222222222222222222", createdAt: 1, epochs: 0 },
      { id: "0x3333333333333333333333333333333333333333", createdAt: 5, epochs: 2 },
    ]);
  });
});
`,
)
