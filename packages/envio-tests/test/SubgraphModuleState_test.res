// graph-node instantiates the mapping's WASM module for every trigger
// (runtime/wasm/src/mapping.rs: `instantiate_module`, then `handle_trigger`),
// so a file's top-level code runs again in each trigger's context and no global
// keeps what an earlier handler left in it. SporkDAO numbers its TransferData
// from a module counter, morpho-blue caches its protocol entity in a module
// variable; both read the first trigger's state in every later one here.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Seen
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Seen @entity {
  id: ID!
  counter: Int!
  firstSighting: Boolean!
  staticCount: Int!
  network: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/state.ts",
      `
import { dataSource } from "@graphprotocol/graph-ts";

export let counter: i32 = 0;
export const sightings = new Map<string, bool>();
export const NETWORK = dataSource.network();

export class Tally {
  static count: i32 = 0;
}

export function next(): i32 {
  counter += 1;
  return counter;
}
`,
    ),
    (
      "src/registry.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { next, sightings, NETWORK, Tally } from "./state";

export function handleNewOwner(event: any): void {
  let seen = new Entity();
  let first = !sightings.has("owner");
  sightings.set("owner", true);
  Tally.count += 1;
  seen.setI32("counter", next());
  seen.setBoolean("firstSighting", first);
  seen.setI32("staticCount", Tally.count);
  seen.setString("network", NETWORK);
  store.set("Seen", event.params.nonce.toString(), seen);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("module state", () => {
  it("starts every trigger from the files' top-level code", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Registry", event: "NewOwner", params: { nonce: 1n } },
            { contract: "Registry", event: "NewOwner", params: { nonce: 2n } },
          ],
        },
      },
    });

    t.expect(await indexer.Seen.getAll()).toEqual([
      { id: "1", counter: 1, firstSighting: true, staticCount: 1, network: "mainnet" },
      { id: "2", counter: 1, firstSighting: true, staticCount: 1, network: "mainnet" },
    ]);
  });
});
`,
)
