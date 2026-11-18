// A save that sets every field of its entity leaves nothing for the merge onto
// the stored entity to keep, so it needn't read the store. Reading it anyway
// cost every insert-only event (a Transfer stored once under a fresh id) a
// database lookup and a second preload round, while the event waited for it.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - TransferEvent
        - Holder
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Transfer(uint256)
          handler: handleTransfer
        - event: Touch(uint256)
          handler: handleTouch
      file: ./src/token.ts
`,
  ~schema=`
type TransferEvent @entity {
  id: ID!
  amount: BigInt!
  memo: String
}

type Holder @entity {
  id: ID!
  amount: BigInt!
  memo: String
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Transfer","anonymous":false,"inputs":[{"name":"value","type":"uint256","indexed":false}]},{"type":"event","name":"Touch","anonymous":false,"inputs":[{"name":"value","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleTransfer(event: any): void {
  (globalThis as any).transferRuns = ((globalThis as any).transferRuns ?? 0) + 1;
  let transfer = new Entity();
  transfer.setBigInt("amount", event.params.value);
  transfer.set("memo", Value.fromNull());
  store.set("TransferEvent", event.block.number.toString(), transfer);

  // Every field again, over an entity an earlier event stored: replaced whole.
  let holder = new Entity();
  holder.setBigInt("amount", event.params.value);
  holder.set("memo", Value.fromNull());
  store.set("Holder", "h", holder);
}

export function handleTouch(event: any): void {
  // Leaves amount unset, so it keeps the stored value.
  let holder = new Entity();
  holder.setString("memo", "touched");
  store.set("Holder", "h", holder);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const TRANSFERS = 8;

const run = async () => {
  const indexer = createTestIndexer();
  (globalThis as any).transferRuns = 0;
  await indexer.process({
    chains: {
      1: {
        startBlock: 0,
        endBlock: 100,
        simulate: [
          ...Array.from({ length: TRANSFERS }, (_, index) => ({
            contract: "Token",
            event: "Transfer",
            params: { value: BigInt(index + 1) },
            block: { number: index + 1 },
          })),
          { contract: "Token", event: "Touch", params: { value: 0n }, block: { number: 50 } },
        ],
      },
    },
  });
  return indexer;
};

describe("saving every field of an entity", () => {
  it("is preloaded with the others in one round, then processed", async (t) => {
    await run();
    t.expect((globalThis as any).transferRuns).toBe(2 * TRANSFERS);
  });

  it("stores what a merge onto the stored entity would", async (t) => {
    const indexer = await run();
    t.expect({
      transfers: (await indexer.TransferEvent.getAll()).length,
      holder: await indexer.Holder.get("h"),
    }).toEqual({
      transfers: TRANSFERS,
      holder: { id: "h", amount: BigInt(TRANSFERS), memo: "touched" },
    });
  });
});
`,
)
