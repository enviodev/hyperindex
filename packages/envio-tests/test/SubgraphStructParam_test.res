// An event with a struct parameter — Nouns' `NounCreated(uint256, Seed)`, SSV's
// `ValidatorAdded(..., Cluster)`. envio decodes a struct whose ABI names its
// components as an object keyed by those names; the shim read it by position,
// got `undefined` for every field, and since every parameter is converted
// together, even `event.params.tokenId` threw. And a struct array's elements,
// read through `toTupleArray<Struct>()`, are the struct graph codegen names —
// GMX's event data is one — but the type argument was erased with the rest.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: NounsToken
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: NounsToken
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Seed
      abis:
        - name: NounsToken
          file: ./abis/NounsToken.json
      eventHandlers:
        - event: NounCreated(indexed uint256,(uint48,uint48,uint48,uint48,uint48))
          handler: handleNounCreated
        - event: Batch((uint48,address)[])
          handler: handleBatch
      file: ./src/token.ts
`,
  ~schema=`
type Seed @entity {
  id: ID!
  values: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/NounsToken.json",
      `[{"type":"event","name":"NounCreated","anonymous":false,"inputs":[{"name":"tokenId","type":"uint256","indexed":true},{"name":"seed","type":"tuple","indexed":false,"internalType":"struct INounsSeeder.Seed","components":[{"name":"background","type":"uint48"},{"name":"body","type":"uint48"},{"name":"accessory","type":"uint48"},{"name":"head","type":"uint48"},{"name":"glasses","type":"uint48"}]}]},{"type":"event","name":"Batch","anonymous":false,"inputs":[{"name":"items","type":"tuple[]","indexed":false,"components":[{"name":"id","type":"uint48"},{"name":"owner","type":"address"}]}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { Address, BigInt, Entity, ethereum, store } from "@graphprotocol/graph-ts";

export function handleNounCreated(event: ethereum.Event): void {
  let tokenId: BigInt = event.parameters[0].value.toBigInt();
  let seed = event.parameters[1].value.toTuple();
  let values: string[] = [];
  for (let i = 0; i < seed.length; i++) values.push(seed[i].toBigInt().toString());
  let entity = new Entity();
  entity.setString("values", values.join(","));
  store.set("Seed", tokenId.toString(), entity);
}

// What graph codegen emits for a struct array: the generic names the element's
// class, whose getters read the tuple.
class BatchItemsStruct extends ethereum.Tuple {
  get id(): BigInt {
    return this[0].toBigInt();
  }
  get owner(): Address {
    return this[1].toAddress();
  }
}

export function handleBatch(event: ethereum.Event): void {
  let items = event.parameters[0].value.toTupleArray<BatchItemsStruct>();
  let values: string[] = [];
  for (let i = 0; i < items.length; i++) {
    values.push(items[i].id.toString() + "@" + items[i].owner.toHexString());
  }
  let entity = new Entity();
  entity.setString("values", values.join(","));
  store.set("Seed", "batch", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const owner = "0x2222222222222222222222222222222222222222";

describe("a struct event parameter", () => {
  it("reads as a tuple in ABI order, alongside the other parameters", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "NounsToken",
              event: "NounCreated",
              params: { tokenId: 7n, seed: { background: 1n, body: 14n, accessory: 3n, head: 200n, glasses: 9n } },
              block: { number: 10 },
            },
            {
              contract: "NounsToken",
              event: "Batch",
              params: { items: [{ id: 5n, owner }, { id: 6n, owner }] },
              block: { number: 11 },
            },
          ],
        },
      },
    });

    t.expect((await indexer.Seed.getAll()).sort((a, b) => a.id.localeCompare(b.id))).toEqual([
      { id: "7", values: "1,14,3,200,9" },
      { id: "batch", values: "5@" + owner + ",6@" + owner },
    ]);
  });
});
`,
)
