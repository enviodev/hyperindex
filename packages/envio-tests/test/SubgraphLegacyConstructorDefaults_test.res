// graph-cli 0.22.0 through 0.29.0 wrote an entity constructor that sets every
// non-nullable, non-derived field to a zero value (`_generateDefaultFieldValues`
// in src/codegen/schema.js, defaults from ASSEMBLYSCRIPT_TO_VALUE). A subgraph
// built with one — swaap-labs/swaap-subgraph-v1 pins 0.25.3 and never sets its
// DailyActivity's swapCount — saves those zeros on graph-node, and a fresh
// instance saved over a stored entity resets the fields it didn't set. Its
// graph-cli no longer installs (a dead git dependency), so envio writes the
// generated code itself, and has to write it the way that version did.

let manifest = `
specVersion: 0.0.4
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.5
      language: wasm/assemblyscript
      entities:
        - Activity
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Swapped(uint256)
          handler: handleSwapped
      file: ./src/pool.ts
`

let schema = `
type Activity @entity {
  id: ID!
  pool: Pool!
  name: String!
  swapCount: Int!
  volume: BigInt!
  fees: BigDecimal!
  owner: Bytes!
  active: Boolean!
  tokens: [String!]!
  sponsor: Bytes
  swaps: [Swap!]! @derivedFrom(field: "activity")
}

type Pool @entity {
  id: ID!
}

type Swap @entity {
  id: ID!
  activity: Activity!
}
`

let abi = `[{"type":"event","name":"Swapped","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Pool.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Pool.json", abi),
    (
      "package.json",
      `{"name":"pools","devDependencies":{"@graphprotocol/graph-cli":"0.25.3","@graphprotocol/graph-ts":"0.24.1"}}`,
    ),
    ("generated/.gitkeep", ""),
    (
      "src/pool.ts",
      `
import { Swapped } from "../generated/Pool/Pool";
import { Activity } from "../generated/schema";

export function handleSwapped(event: Swapped): void {
  let activity = new Activity("a");
  if (event.params.amount.toI32() == 1) {
    activity.name = "first";
  } else {
    activity.swapCount = 2;
  }
  activity.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const swapped = (amount: bigint) => ({ contract: "Pool", event: "Swapped", params: { amount } });

describe("an entity constructor from graph-cli 0.22-0.29", () => {
  it("sets the non-nullable fields to zero values, over what was stored", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [swapped(1n)] } } });
    const first = await indexer.Activity.getOrThrow("a");

    await indexer.process({ chains: { 1: { simulate: [swapped(2n)] } } });
    const second = await indexer.Activity.getOrThrow("a");

    const shape = (row: any) => ({ ...row, owner: Buffer.from(row.owner).toString("hex"), fees: row.fees.toString() });
    t.expect([shape(first), shape(second)]).toEqual([
      {
        id: "a", pool_id: "", name: "first", swapCount: 0, volume: 0n, fees: "0",
        owner: "", active: false, tokens: [], sponsor: null,
      },
      {
        id: "a", pool_id: "", name: "", swapCount: 2, volume: 0n, fees: "0",
        owner: "", active: false, tokens: [], sponsor: null,
      },
    ]);
  });
});
`,
)
