// A template's block handlers run once per instance, for every block from the
// block that created it (Moonwell's price feeds). Before, the manifest was
// refused.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Deployer
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Deployer
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Tick
      abis:
        - name: Deployer
          file: ./abis/Deployer.json
      eventHandlers:
        - event: Deployed(address)
          handler: handleDeployed
      file: ./src/deployer.ts
templates:
  - kind: ethereum/contract
    name: Feed
    network: mainnet
    source:
      abi: Feed
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Tick
      abis:
        - name: Feed
          file: ./abis/Feed.json
      eventHandlers:
        - event: Updated(uint256)
          handler: handleUpdated
      blockHandlers:
        - handler: handleBlock
      file: ./src/feed.ts
`,
  ~schema=`
type Tick @entity {
  id: ID!
  feed: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Deployer.json",
      `[{"type":"event","name":"Deployed","anonymous":false,"inputs":[{"name":"feed","type":"address","indexed":false}]}]`,
    ),
    (
      "abis/Feed.json",
      `[{"type":"event","name":"Updated","anonymous":false,"inputs":[{"name":"value","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/deployer.ts",
      `
import { Address, DataSourceTemplate } from "@graphprotocol/graph-ts";

export function handleDeployed(event: any): void {
  let feed: Address = event.params.feed;
  DataSourceTemplate.create("Feed", [feed.toHexString()]);
}
`,
    ),
    (
      "src/feed.ts",
      `
import { dataSource, Entity, store, Value } from "@graphprotocol/graph-ts";

export function handleUpdated(event: any): void {}

export function handleBlock(block: any): void {
  let tick = new Entity();
  tick.set("id", Value.fromString(dataSource.address().toHexString() + ":" + block.number.toString()));
  tick.set("feed", Value.fromString(dataSource.address().toHexString()));
  store.set("Tick", dataSource.address().toHexString() + ":" + block.number.toString(), tick);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const feed = "0x2222222222222222222222222222222222222222";

describe("a template's block handler", () => {
  it("runs for its instance from the creation block on", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 12,
          simulate: [
            {
              contract: "Deployer",
              event: "Deployed",
              params: { feed },
              block: { number: 10 },
              logIndex: 1,
            },
          ],
        },
      },
    });

    const ticks = await indexer.Tick.getAll();
    t.expect(ticks.map((tick) => tick.id).sort()).toEqual([
      feed + ":10",
      feed + ":11",
      feed + ":12",
    ]);
  });
});
`,
)
