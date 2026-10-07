// A contract's constructor logs before the factory that deployed it announces
// it, so a template's events in its creation block come earlier in the block
// than the `create()` that registers it. graph-node runs a new data source's
// creation-block events after the block's other triggers, and Reserve's
// governor mapping relies on that: the entity it loads is the one the factory
// handler stores. Strict log order would run it first and find nothing.
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
        - Governance
      abis:
        - name: Deployer
          file: ./abis/Deployer.json
      eventHandlers:
        - event: Deployed(address)
          handler: handleDeployed
      file: ./src/deployer.ts
templates:
  - kind: ethereum/contract
    name: Governor
    network: mainnet
    source:
      abi: Governor
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Governance
      abis:
        - name: Governor
          file: ./abis/Governor.json
      eventHandlers:
        - event: VotingDelaySet(uint256)
          handler: handleVotingDelaySet
      file: ./src/governor.ts
`,
  ~schema=`
type Governance @entity {
  id: ID!
  votingDelay: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Deployer.json",
      `[{"type":"event","name":"Deployed","anonymous":false,"inputs":[{"name":"governor","type":"address","indexed":false}]}]`,
    ),
    (
      "abis/Governor.json",
      `[{"type":"event","name":"VotingDelaySet","anonymous":false,"inputs":[{"name":"delay","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/deployer.ts",
      `
import { Address, BigInt, DataSourceTemplate, Entity, store } from "@graphprotocol/graph-ts";

export function handleDeployed(event: any): void {
  let governor: Address = event.params.governor;
  let governance = new Entity();
  governance.setBigInt("votingDelay", BigInt.fromI32(0));
  store.set("Governance", governor.toHexString(), governance);
  DataSourceTemplate.create("Governor", [governor.toHexString()]);
}
`,
    ),
    (
      "src/governor.ts",
      `
import { BigInt, dataSource, store } from "@graphprotocol/graph-ts";

export function handleVotingDelaySet(event: any): void {
  let governance = store.get("Governance", dataSource.address().toHexString())!;
  let delay: BigInt = event.params.delay;
  governance.setBigInt("votingDelay", delay);
  store.set("Governance", dataSource.address().toHexString(), governance);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const governor = "0x2222222222222222222222222222222222222222";

describe("a template's events in the block that created it", () => {
  it("run after the block's other events, as on graph-node", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Governor",
              event: "VotingDelaySet",
              srcAddress: governor,
              params: { delay: 7n },
              block: { number: 10 },
              logIndex: 558,
            },
            {
              contract: "Deployer",
              event: "Deployed",
              params: { governor },
              block: { number: 10 },
              logIndex: 573,
            },
          ],
        },
      },
    });

    t.expect(await indexer.Governance.getAll()).toEqual([{ id: governor, votingDelay: 7n }]);
  });
});
`,
)
