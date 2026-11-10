// AssemblyScript's own Map and Set (std/assembly/map.ts, set.ts): `keys()` and
// `values()` are arrays, `map[key]` is `@operator("[]") get` and `map[key] = v`
// its `set`, `set[key]` is `has`, and `get` of a missing key throws "Key does not
// exist". Intent-X's analytics loop over `dictionary.keys().length`, Reserve
// reads `RSR_CHAINLINK_CONTRACT_ADDRESS[network]`: on JavaScript's Map the loop
// ran zero times and the read was undefined.
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
        - Check
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Check @entity {
  id: ID!
  keys: String!
  values: String!
  indexed: String!
  setValues: String!
  inSet: Boolean!
  size: Int!
  missingThrows: Boolean!
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
      "src/addresses.ts",
      `
export const FEEDS = new Map<string, string>();
FEEDS.set("mainnet", "0xfeed");
`,
    ),
    (
      "src/registry.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { FEEDS } from "./addresses";

export function handleNewOwner(event: any): void {
  let totals = new Map<string, i32>();
  totals.set("a", 1);
  totals["b"] = 2;
  totals.set("a", 3);

  let keys = "";
  for (let i = 0; i < totals.keys().length; i++) keys += totals.keys()[i];
  let values = "";
  let all = totals.values();
  for (let i = 0; i < all.length; i++) values += all[i].toString();

  let seen = new Set<string>();
  seen.add("x");
  seen["y"] = true;

  let check = new Entity();
  check.setString("keys", keys);
  check.setString("values", values);
  check.setString("indexed", FEEDS["mainnet"] + ":" + totals["b"].toString());
  check.setString("setValues", seen.values().join(","));
  check.setBoolean("inSet", seen["y"]);
  check.setI32("size", totals.size);
  check.setBoolean("missingThrows", event.params.nonce.toI32() == 1);
  if (event.params.nonce.toI32() == 2) totals.get("nope");
  store.set("Check", event.params.nonce.toString(), check);
}
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

const probe = (nonce: bigint) => ({
  chains: { 1: { simulate: [{ contract: "Registry" as const, event: "NewOwner" as const, params: { nonce } }] } },
});

describe("AssemblyScript's Map and Set", () => {
  it("lists keys and values as arrays and reads and writes through []", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process(probe(1n));
    t.expect(await indexer.Check.getOrThrow("1")).toEqual({
      id: "1",
      keys: "ab",
      values: "32",
      indexed: "0xfeed:2",
      setValues: "x,y",
      inSet: true,
      size: 2,
      missingThrows: true,
    });
  });

  it("throws on a missing key, as get does in AssemblyScript", async () => {
    await expect(createTestIndexer().process(probe(2n))).rejects.toThrow("Key does not exist");
  });
});
`,
)
