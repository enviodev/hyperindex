// An RPC response holds each eth_getLogs selection's logs one after another, so
// its items are not in block order: Safe's 1.3.0 factories' ProxyCreations came
// before the 1.4.1 ones' of earlier blocks. Every one of them is applied, as main
// applies a response, whatever order they arrive in.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
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
        - Child
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Create(address)
          handler: handleCreate
      file: ./src/factory.ts
templates:
  - kind: ethereum/contract
    name: ChildContract
    network: mainnet
    source:
      abi: Factory
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Child
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Create(address)
          handler: handleCreate
      file: ./src/factory.ts
`

let abi = `[{"type":"event","name":"Create","anonymous":false,"inputs":[{"name":"child","type":"address","indexed":false}]}]`

let schema = `
type Child @entity {
  id: ID!
  block: Int!
}
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("./abis/Factory.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Factory.json", abi),
    (
      "src/factory.ts",
      `
import { Address, Entity, Value, ethereum, store } from "@graphprotocol/graph-ts";
import { ChildContract } from "../generated/templates";

export function handleCreate(event: ethereum.Event): void {
  let child: Address = event.parameters[0].value.toAddress();
  ChildContract.create(child);
  let entity = new Entity();
  entity.set("id", Value.fromString(child.toHexString()));
  entity.set("block", Value.fromI32(event.block.number.toI32()));
  store.set("Child", child.toHexString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const create = (block) => ({
  contract: "Factory",
  event: "Create",
  params: { child: "0x" + block.toString(16).padStart(40, "0") },
  block: { number: block },
});

describe("a response whose register passes arrive out of block order", () => {
  it("applies every event, the earlier blocks listed last included", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 300,
          simulate: [
            ...Array.from({ length: 150 }, (_, index) => create(100 + index)),
            ...Array.from({ length: 50 }, (_, index) => create(1 + index)),
          ],
        },
      },
    });
    const children = await indexer.Child.getAll();
    t.expect({
      count: children.length,
      earliest: Math.min(...children.map((child) => child.block)),
    }).toEqual({ count: 200, earliest: 1 });
  });
});
`,
)
