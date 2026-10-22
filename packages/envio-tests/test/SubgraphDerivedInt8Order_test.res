// graph-node answers a derived field's load() in entity key order
// (EntityCache::load_related walks a BTreeSet of keys), and an Int8 id orders
// as a number: 9 before 10.
let manifest = `
specVersion: 1.1.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Contract
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Contract
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities:
        - Owner
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: Trigger(uint16)
          handler: handleTrigger
      file: ./src/mapping.ts
`

let schema = `
type Owner @entity {
  id: ID!
  points: [Point!]! @derivedFrom(field: "owner")
}

type Point @entity {
  id: Int8!
  owner: Owner!
}

type Seen @entity {
  id: ID!
  order: [Int8!]!
}
`

let abi = `[{"type":"event","name":"Trigger","anonymous":false,"inputs":[{"name":"x","type":"uint16","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Contract.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Contract.json", abi),
    ("generated/.gitkeep", ""),
    (
      "src/mapping.ts",
      `
import { Trigger } from "../generated/Contract/Contract";
import { Owner, Point, Seen } from "../generated/schema";

export function handleTrigger(event: Trigger): void {
  let owner = new Owner("o");
  owner.save();
  for (let i = 8; i <= 10; i++) {
    let point = new Point(i64(i));
    point.owner = "o";
    point.save();
  }
  let points = Owner.load("o")!.points.load();
  let seen = new Seen("o");
  let order: i64[] = [];
  for (let i = 0; i < points.length; i++) order.push(points[i].id);
  seen.order = order;
  seen.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a derived field over Int8 ids", () => {
  it("loads in numeric id order", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Contract", event: "Trigger", params: { x: 7n } }] } },
    });
    t.expect((await indexer.Seen.getAll()).map((row: any) => row.order.map(String))).toEqual([["8", "9", "10"]]);
  });
});
`,
)
