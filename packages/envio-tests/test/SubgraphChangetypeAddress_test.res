// `changetype<usize>(ref)` reads a reference's address in AssemblyScript: 0
// for null, a distinct nonzero number per object. predictfun-orderbook tests a
// load with `if (changetype<usize>(m) != 0)`; an identity changetype handed the
// entity itself to `!=`, and comparing it with 0 threw.
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
        - Seed
        - Check
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(address)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Seed @entity {
  id: ID!
}

type Check @entity {
  id: ID!
  foundIsSet: Boolean!
  missingIsSet: Boolean!
  missingIsZero: Boolean!
  sameObjectSameAddress: Boolean!
  otherObjectOtherAddress: Boolean!
  integerKeepsValue: Boolean!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"owner","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleNewOwner(event: any): void {
  store.set("Seed", "seed", new Entity());

  let found = store.get("Seed", "seed");
  let missing = store.get("Seed", "nope");
  let other = new Entity();
  let n: u32 = 7;

  let check = new Entity();
  check.setBoolean("foundIsSet", changetype<usize>(found) != 0);
  check.setBoolean("missingIsSet", changetype<usize>(missing) != 0);
  check.setBoolean("missingIsZero", changetype<usize>(missing) == 0);
  check.setBoolean("sameObjectSameAddress", changetype<usize>(found) == changetype<usize>(found));
  check.setBoolean("otherObjectOtherAddress", changetype<usize>(found) != changetype<usize>(other));
  check.setBoolean("integerKeepsValue", changetype<i32>(n) == 7);
  store.set("Check", "c1", check);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("changetype to an integer", () => {
  it("reads null as 0 and an object as an address of its own", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Registry", event: "NewOwner", params: { owner: "0x2222222222222222222222222222222222222222" } },
          ],
        },
      },
    });

    t.expect(await indexer.Check.getOrThrow("c1")).toEqual({
      id: "c1",
      foundIsSet: true,
      missingIsSet: false,
      missingIsZero: true,
      sameObjectSameAddress: true,
      otherObjectOtherAddress: true,
      integerKeepsValue: true,
    });
  });
});
`,
)
