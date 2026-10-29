// FastLane-Labs/auction-subgraph builds a withdrawal id with `uuid()` from the
// JavaScript package uuidv4. asc compiles AssemblyScript only — a package's
// `ascMain`, assembly/index.ts or a .ts entry — so `graph build` can't build
// that mapping. envio ran the JavaScript instead: a fresh random id on every
// replay, so the handler never settled ("gave up after 10000 rounds").
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.4
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Auction
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Auction
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.6
      language: wasm/assemblyscript
      entities:
        - Withdrawal
      abis:
        - name: Auction
          file: ./abis/Auction.json
      eventHandlers:
        - event: Withdrawn(uint256)
          handler: handleWithdrawn
      file: ./src/auction.ts
`,
  ~schema=`
type Withdrawal @entity {
  id: ID!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Auction.json",
      `[{"type":"event","name":"Withdrawn","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "node_modules/uuidv4/package.json",
      `{"name":"uuidv4","version":"6.2.13","main":"build/lib/uuidv4.js"}`,
    ),
    (
      "node_modules/uuidv4/build/lib/uuidv4.js",
      `exports.uuid = () => Math.random().toString(16).slice(2);`,
    ),
    (
      "src/auction.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { uuid } from "uuidv4";

export function handleWithdrawn(event: any): void {
  store.set("Withdrawal", uuid(), new Entity());
}
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a mapping importing a JavaScript package", () => {
  it("is refused at load, as asc refuses it", async () => {
    await expect(
      createTestIndexer().process({
        chains: { 1: { simulate: [{ contract: "Auction", event: "Withdrawn", params: { amount: 1n } }] } },
      }),
    ).rejects.toThrow(
      'src/auction.ts imports the JavaScript package "uuidv4", which AssemblyScript can\\'t compile',
    );
  });
});
`,
)
