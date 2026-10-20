// graph-node gives a template instance its creation block as start block
// (chain/ethereum/src/data_source.rs): a `once` handler runs at that block and
// a `polling` one where `(block - start) % every == 0`, so each instance keeps
// its own schedule (OasisDEX summer-earn's ChainlinkProxy template has a
// `once`). The manifest was refused.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.8
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
    name: Oracle
    network: mainnet
    source:
      abi: Oracle
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Tick
      abis:
        - name: Oracle
          file: ./abis/Feed.json
      eventHandlers:
        - event: Updated(uint256)
          handler: handleUpdated
      blockHandlers:
        - handler: handleOnce
          filter:
            kind: once
        - handler: handlePoll
          filter:
            kind: polling
            every: 3
      file: ./src/oracle.ts
`,
  ~schema=`
type Tick @entity {
  id: ID!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Deployer.json",
      `[{"type":"event","name":"Deployed","anonymous":false,"inputs":[{"name":"feed","type":"address","indexed":false}]}]`,
    ),
    (
      "abis/Oracle.json",
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
  DataSourceTemplate.create("Oracle", [feed.toHexString()]);
}
`,
    ),
    (
      "src/oracle.ts",
      `
import { dataSource, Entity, store, Value } from "@graphprotocol/graph-ts";

export function handleUpdated(event: any): void {}

export function handleOnce(block: any): void {
  let tick = new Entity();
  tick.set("id", Value.fromString("once:" + dataSource.address().toHexString().slice(0, 4) + ":" + block.number.toString()));
  store.set("Tick", "once:" + dataSource.address().toHexString().slice(0, 4) + ":" + block.number.toString(), tick);
}

export function handlePoll(block: any): void {
  let tick = new Entity();
  tick.set("id", Value.fromString("poll:" + dataSource.address().toHexString().slice(0, 4) + ":" + block.number.toString()));
  store.set("Tick", "poll:" + dataSource.address().toHexString().slice(0, 4) + ":" + block.number.toString(), tick);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const deployed = (feed: string, block: number) => ({
  contract: "Deployer",
  event: "Deployed",
  params: { feed },
  block: { number: block },
  logIndex: 1,
});

describe("once and polling block handlers on a template", () => {
  it("run on each instance's own schedule from its creation block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 17,
          simulate: [
            deployed("0x4444444444444444444444444444444444444444", 10),
            deployed("0x5555555555555555555555555555555555555555", 11),
          ],
        },
      },
    });
    t.expect((await indexer.Tick.getAll()).map((tick: any) => tick.id).sort()).toEqual([
      "once:0x44:10",
      "once:0x55:11",
      "poll:0x44:10",
      "poll:0x44:13",
      "poll:0x44:16",
      "poll:0x55:11",
      "poll:0x55:14",
      "poll:0x55:17",
    ]);
  });
});
`,
)
