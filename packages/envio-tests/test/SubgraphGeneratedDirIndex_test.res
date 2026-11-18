// tornado-dao/tornado-subgraph's instance mapping imports its event classes
// from the generated directory itself (`from '../generated'`). graph codegen
// writes no index.ts there; the repo's own manifest script (a node script,
// which envio doesn't run) writes `export * from "./Instance-0.1-bnb/Instance"`,
// the generated module of the network's first Instance data source. Every data
// source that uses this mapping has the same ABI, so the module the names come
// from is the one generated for each of them: envio writes the index, with a
// warning.
let manifest = `
specVersion: 0.0.2
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Instance-0.1-bnb
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Instance
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.4
      language: wasm/assemblyscript
      entities:
        - Deposit
      abis:
        - name: Instance
          file: ./abis/Instance.json
      eventHandlers:
        - event: Deposit(indexed bytes32,uint32,uint256)
          handler: handleDeposit
      file: ./src/mapping-instance.ts
  - kind: ethereum/contract
    name: Instance-1-bnb
    network: mainnet
    source:
      address: "0x2222222222222222222222222222222222222222"
      abi: Instance
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.4
      language: wasm/assemblyscript
      entities:
        - Deposit
      abis:
        - name: Instance
          file: ./abis/Instance.json
      eventHandlers:
        - event: Deposit(indexed bytes32,uint32,uint256)
          handler: handleDeposit
      file: ./src/mapping-instance.ts
  - kind: ethereum/contract
    name: Proxy
    network: mainnet
    source:
      address: "0x3333333333333333333333333333333333333333"
      abi: Proxy
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.4
      language: wasm/assemblyscript
      entities:
        - Note
      abis:
        - name: Proxy
          file: ./abis/Proxy.json
      eventHandlers:
        - event: EncryptedNote(indexed address,bytes)
          handler: handleEncryptedNote
      file: ./src/mapping-proxy.ts
`

let schema = `
type Deposit @entity {
  id: ID!
  leafIndex: BigInt!
}

type Note @entity {
  id: ID!
}
`

let instanceAbi = `[{"type":"event","name":"Deposit","anonymous":false,"inputs":[{"name":"commitment","type":"bytes32","indexed":true},{"name":"leafIndex","type":"uint32","indexed":false},{"name":"timestamp","type":"uint256","indexed":false}]}]`

let proxyAbi = `[{"type":"event","name":"EncryptedNote","anonymous":false,"inputs":[{"name":"sender","type":"address","indexed":true},{"name":"encryptedNote","type":"bytes","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Instance.json", instanceAbi), ("abis/Proxy.json", proxyAbi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Instance.json", instanceAbi),
    ("abis/Proxy.json", proxyAbi),
    (
      "src/mapping-instance.ts",
      `
import { BigInt } from "@graphprotocol/graph-ts";
import { Deposit } from '../generated';
import { Deposit as DepositEntity } from '../generated/schema';

export function handleDeposit(event: Deposit): void {
  let entity = new DepositEntity(event.address.toHexString() + '-' + event.logIndex.toString());
  entity.leafIndex = BigInt.fromI32(event.params.leafIndex);
  entity.save();
}
`,
    ),
    (
      "src/mapping-proxy.ts",
      `
import { EncryptedNote } from '../generated/Proxy/Proxy';
import { Note } from '../generated/schema';

export function handleEncryptedNote(event: EncryptedNote): void {
  new Note(event.transaction.hash.toHexString()).save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a mapping importing the generated directory itself", () => {
  it("reads the event classes of its data sources' ABI", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Instance_1_bnb",
              event: "Deposit",
              srcAddress: "0x2222222222222222222222222222222222222222",
              params: { commitment: "0x" + "ab".repeat(32), leafIndex: 7n, timestamp: 1n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Deposit.getAll()).toEqual([
      { id: "0x2222222222222222222222222222222222222222-0", leafIndex: 7n },
    ]);
  });
});
`,
)
