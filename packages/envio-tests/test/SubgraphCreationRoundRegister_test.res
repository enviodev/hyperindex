// The register pass decides at fetch time which addresses a handler creates, and
// reads only what earlier register passes saved. A creation-block event logged
// before the deployer's still runs after it on graph-node, so its register pass
// must read what the deployer's pass saved: Reserve's DTF RoleGranted creates a
// timelock only for a DTF the deployer's handler stored, and with log-order
// positions the template was never registered and its events were dropped.
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
        - Config
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
type Config @entity {
  id: ID!
  ready: Boolean!
}

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
  let config = new Entity();
  config.setBoolean("ready", true);
  store.set("Config", vault.toHexString(), config);
  DataSourceTemplate.create("Vault", [vault.toHexString()]);
}

export function handleOwned(event: any): void {
  if (store.get("Config", dataSource.address().toHexString()) == null) return;
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

describe("a register pass for a creation-block event", () => {
  it("register passes read what the creating handler's pass saved", async (t) => {
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
              logIndex: 558,
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
