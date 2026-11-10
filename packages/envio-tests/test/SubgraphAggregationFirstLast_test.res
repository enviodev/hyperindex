// graph-node v0.42 lets `first` and `last` aggregate a String, a Bytes or an
// entity reference as well as a number (#6225; graph/src/schema/input/mod.rs
// accepts them for first/last only, store/postgres/src/relational/rollup.rs
// picks the value by id with arg_min/arg_max). The translator refused any
// aggregate that wasn't Int, Int8, BigInt or BigDecimal.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.3.0
schema:
  file: ./schema.graphql
features:
  - aggregations
dataSources:
  - kind: ethereum/contract
    name: Market
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Market
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities:
        - Trade
      abis:
        - name: Market
          file: ./abis/Market.json
      eventHandlers:
        - event: Traded(string,address,string)
          handler: handleTraded
      file: ./src/market.ts
`,
  ~schema=`
type Token @entity {
  id: ID!
}

type Trade @entity(timeseries: true) {
  id: Int8!
  timestamp: Timestamp!
  token: Token!
  trader: Bytes!
  note: String!
}

type MarketStats @aggregation(intervals: ["hour"], source: "Trade") {
  id: Int8!
  timestamp: Timestamp!
  trades: Int! @aggregate(fn: "count")
  firstNote: String! @aggregate(fn: "first", arg: "note", cumulative: true)
  lastTrader: Bytes! @aggregate(fn: "last", arg: "trader")
  lastToken: Token! @aggregate(fn: "last", arg: "token", cumulative: true)
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Market.json",
      `[{"type":"event","name":"Traded","anonymous":false,"inputs":[{"name":"token","type":"string","indexed":false},{"name":"trader","type":"address","indexed":false},{"name":"note","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/market.ts",
      `
import { Entity, store, Value } from "@graphprotocol/graph-ts";

export function handleTraded(event: any): void {
  let trade = new Entity();
  trade.setString("token", event.params.token);
  trade.set("trader", Value.fromBytes(event.parameters[1].value.toAddress()));
  trade.setString("note", event.params.note);
  store.set("Trade", "ignored", trade);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const hour = 3600 * 500000;
const traded = (block: number, seconds: number, token: string, trader: string, note: string) => ({
  contract: "Market",
  event: "Traded",
  params: { token, trader, note },
  block: { number: block, timestamp: hour + seconds },
});

describe("first and last of non-numeric fields", () => {
  it("roll up the earliest and latest values by id", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            traded(1, 10, "A", "0x2222222222222222222222222222222222222222", "opening"),
            traded(2, 20, "B", "0x3333333333333333333333333333333333333333", "middle"),
            traded(3, 30, "C", "0x4444444444444444444444444444444444444444", "closing"),
            traded(4, 3610, "D", "0x5555555555555555555555555555555555555555", "next hour"),
            traded(5, 7210, "E", "0x6666666666666666666666666666666666666666", "third hour"),
          ],
        },
      },
    });
    const rows = (await indexer.MarketStats_hour.getAll()).sort((a: any, b: any) => a.timestamp - b.timestamp);
    t.expect(
      rows.map((row: any) => ({
        trades: row.trades,
        firstNote: row.firstNote,
        lastTrader: Buffer.from(row.lastTrader).toString("hex"),
        lastToken: row.lastToken_id,
      })),
    ).toEqual([
      { trades: 3, firstNote: "opening", lastTrader: "4444444444444444444444444444444444444444", lastToken: "C" },
      { trades: 1, firstNote: "opening", lastTrader: "5555555555555555555555555555555555555555", lastToken: "D" },
    ]);
  });
});
`,
)
