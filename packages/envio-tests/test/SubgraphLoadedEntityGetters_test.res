// `graph codegen` loads an entity as `changetype<Market | null>(store.get(...))`,
// and AssemblyScript reads its fields through the generated getters — which
// answer 0 for an Int (i32) and false for a Boolean the store holds as null.
// The loaded entity kept Entity's prototype instead, its fields read through
// the stored values, and a null Int stayed null: Beanstalk's
// `market.lastHourlySnapshotSeason !== 0` held on a fresh market and
// `.toString()` of the null stopped the first Sunrise.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Season
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Season
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Market
      abis:
        - name: Season
          file: ./abis/Season.json
      eventHandlers:
        - event: Sunrise(uint256)
          handler: handleSunrise
      file: ./src/season.ts
`

let schema = `
type Market @entity {
  id: ID!
  season: Int!
  lastSnapshotSeason: Int
  active: Boolean
  label: String!
}
`

let abi = `[{"type":"event","name":"Sunrise","anonymous":false,"inputs":[{"name":"season","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Season.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Season.json", abi),
    ("generated/.gitkeep", ""),
    (
      "src/season.ts",
      `
import { Sunrise } from "../generated/Season/Season";
import { Market } from "../generated/schema";

export function handleSunrise(event: Sunrise): void {
  let market = Market.load("0");
  if (market == null) {
    market = new Market("0");
    market.season = 0;
    market.label = "";
    market.save();
    market = Market.load("0")!;
  }
  market.season = event.params.season.toI32();
  let last = market.lastSnapshotSeason;
  market.label = market.label + (last !== 0 ? "after:" + last.toString() : "first") + (market.active ? "+" : "-") + ";";
  market.lastSnapshotSeason = market.season;
  market.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a loaded entity", () => {
  it("reads its fields through the generated getters", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Season", event: "Sunrise", params: { season: 1n }, logIndex: 1 },
            { contract: "Season", event: "Sunrise", params: { season: 2n }, logIndex: 2 },
          ],
        },
      },
    });
    t.expect(await indexer.Market.getAll()).toEqual([
      { id: "0", season: 2, lastSnapshotSeason: 2, active: null, label: "first-;after:1-;" },
    ]);
  });
});
`,
)
