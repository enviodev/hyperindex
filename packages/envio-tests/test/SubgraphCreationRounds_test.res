// graph-node runs the data sources a block's triggers create in rounds, breadth
// first: the block's own triggers, then the events of the sources those created,
// then the events of the sources *those* created. Reserve's timelock is one
// round deeper than its stToken: the stToken's OwnershipTransferred (logged
// last) creates the timelock whose RoleGranted (logged first) loads the entity
// that handler stores. Putting both in one "after the block" group ran the
// timelock's event first and found nothing.
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
        - Link
      abis:
        - name: Deployer
          file: ./abis/Deployer.json
      eventHandlers:
        - event: Deployed(address)
          handler: handleDeployed
      file: ./src/mappings.ts
templates:
  - kind: ethereum/contract
    name: Vault
    network: mainnet
    source:
      abi: Vault
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Link
      abis:
        - name: Vault
          file: ./abis/Vault.json
      eventHandlers:
        - event: Owned(address)
          handler: handleOwned
      file: ./src/mappings.ts
  - kind: ethereum/contract
    name: Timelock
    network: mainnet
    source:
      abi: Timelock
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Link
      abis:
        - name: Timelock
          file: ./abis/Timelock.json
      eventHandlers:
        - event: Granted(uint256)
          handler: handleGranted
      file: ./src/mappings.ts
`,
  ~schema=`
type Link @entity {
  id: ID!
  granted: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Deployer.json",
      `[{"type":"event","name":"Deployed","anonymous":false,"inputs":[{"name":"vault","type":"address","indexed":false}]}]`,
    ),
    (
      "abis/Vault.json",
      `[{"type":"event","name":"Owned","anonymous":false,"inputs":[{"name":"timelock","type":"address","indexed":false}]}]`,
    ),
    (
      "abis/Timelock.json",
      `[{"type":"event","name":"Granted","anonymous":false,"inputs":[{"name":"role","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/mappings.ts",
      `
import { Address, BigInt, DataSourceTemplate, Entity, dataSource, store } from "@graphprotocol/graph-ts";

export function handleDeployed(event: any): void {
  let vault: Address = event.params.vault;
  DataSourceTemplate.create("Vault", [vault.toHexString()]);
}

export function handleOwned(event: any): void {
  let timelock: Address = event.params.timelock;
  let link = new Entity();
  link.setBigInt("granted", BigInt.fromI32(0));
  store.set("Link", timelock.toHexString(), link);
  DataSourceTemplate.create("Timelock", [timelock.toHexString()]);
}

export function handleGranted(event: any): void {
  let link = store.get("Link", dataSource.address().toHexString())!;
  let role: BigInt = event.params.role;
  link.setBigInt("granted", role);
  store.set("Link", dataSource.address().toHexString(), link);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const vault = "0x2222222222222222222222222222222222222222";
const timelock = "0x3333333333333333333333333333333333333333";

describe("data sources created in a block", () => {
  it("run their creation-block events a round after the source that created them", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Timelock",
              event: "Granted",
              srcAddress: timelock,
              params: { role: 9n },
              block: { number: 10 },
              logIndex: 564,
            },
            {
              contract: "Vault",
              event: "Owned",
              srcAddress: vault,
              params: { timelock },
              block: { number: 10 },
              logIndex: 574,
            },
            {
              contract: "Deployer",
              event: "Deployed",
              params: { vault },
              block: { number: 10 },
              logIndex: 575,
            },
          ],
        },
      },
    });

    t.expect(await indexer.Link.getAll()).toEqual([{ id: timelock, granted: 9n }]);
  });
});
`,
)
