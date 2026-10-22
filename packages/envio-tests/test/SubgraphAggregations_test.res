// graph-node's timeseries and aggregations (docs/aggregations.md): a
// `timeseries: true` entity gets an automatic Int8 id and the block's timestamp,
// and each interval of an aggregation is rolled up when a block's time passes the
// end of the bucket the previous block was in. Cumulative aggregates carry the
// group's previous bucket forward.
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
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Trade
      abis:
        - name: Market
          file: ./abis/Market.json
      eventHandlers:
        - event: Traded(string,uint256,string)
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
  amount: BigInt!
  price: BigDecimal!
}

type TradeStats @aggregation(intervals: ["hour", "day"], source: "Trade") {
  id: Int8!
  timestamp: Timestamp!
  token: Token!
  volume: BigDecimal! @aggregate(fn: "sum", arg: "amount * price")
  trades: Int! @aggregate(fn: "count", cumulative: true)
  open: BigDecimal! @aggregate(fn: "first", arg: "price")
  close: BigDecimal! @aggregate(fn: "last", arg: "price")
  high: BigDecimal! @aggregate(fn: "max", arg: "price")
  low: BigDecimal! @aggregate(fn: "min", arg: "price")
  total: BigInt! @aggregate(fn: "sum", arg: "amount", cumulative: true)
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Market.json",
      `[{"type":"event","name":"Traded","anonymous":false,"inputs":[{"name":"token","type":"string","indexed":false},{"name":"amount","type":"uint256","indexed":false},{"name":"price","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/market.ts",
      `
import { BigDecimal, Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleTraded(event: any): void {
  let trade = new Entity();
  trade.setString("token", event.params.token);
  trade.setBigInt("amount", event.params.amount);
  trade.set("price", Value.fromBigDecimal(BigDecimal.fromString(event.params.price)));
  // graph-node overrides the id and the timestamp whatever is passed.
  store.set("Trade", "ignored", trade);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const day = 86400 * 20000;
const trade = (block: number, seconds: number, token: string, amount: number, price: string) => ({
  contract: "Market",
  event: "Traded",
  params: { token, amount: BigInt(amount), price },
  block: { number: block, timestamp: day + seconds },
});
const summary = (row: any) => ({
  at: row.timestamp.toISOString(),
  token: row.token_id,
  volume: row.volume.toString(),
  trades: row.trades,
  open: row.open.toString(),
  close: row.close.toString(),
  high: row.high.toString(),
  low: row.low.toString(),
  total: row.total.toString(),
});
const ordered = (rows: any[]) =>
  rows.map(summary).sort((a, b) => (a.at + a.token < b.at + b.token ? -1 : 1));

describe("a subgraph with a timeseries and an aggregation", () => {
  it("rolls up the hours and days that ended, with cumulative aggregates", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            trade(10, 36100, "A", 5, "1.5"),
            trade(11, 37800, "A", 7, "2.5"),
            trade(12, 38400, "B", 1, "9"),
            trade(13, 39900, "A", 3, "4"),
            trade(14, 46800, "A", 2, "5"),
            trade(15, 88200, "A", 1, "6"),
            trade(16, 93600, "A", 1, "7"),
          ],
        },
      },
    });
    const at = (seconds: number) => new Date((day + seconds) * 1000).toISOString();
    t.expect({
      timeseries: (await indexer.Trade.getAll()).length,
      hours: ordered(await indexer.TradeStats_hour.getAll()),
      days: ordered(await indexer.TradeStats_day.getAll()),
    }).toEqual({
      timeseries: 7,
      hours: [
        { at: at(36000), token: "A", volume: "25", trades: 2, open: "1.5", close: "2.5", high: "2.5", low: "1.5", total: "12" },
        { at: at(36000), token: "B", volume: "9", trades: 1, open: "9", close: "9", high: "9", low: "9", total: "1" },
        { at: at(39600), token: "A", volume: "12", trades: 3, open: "4", close: "4", high: "4", low: "4", total: "15" },
        { at: at(46800), token: "A", volume: "10", trades: 4, open: "5", close: "5", high: "5", low: "5", total: "17" },
        { at: at(86400), token: "A", volume: "6", trades: 5, open: "6", close: "6", high: "6", low: "6", total: "18" },
      ],
      days: [
        { at: at(0), token: "A", volume: "47", trades: 4, open: "1.5", close: "5", high: "5", low: "1.5", total: "17" },
        { at: at(0), token: "B", volume: "9", trades: 1, open: "9", close: "9", high: "9", low: "9", total: "1" },
      ],
    });
  });

  it("picks up where the stored rows left off when the run is split", async (t) => {
    const whole = createTestIndexer();
    const split = createTestIndexer();
    const events = [
      trade(10, 36100, "A", 5, "1.5"),
      trade(11, 37800, "A", 7, "2.5"),
      trade(13, 39900, "A", 3, "4"),
      trade(14, 46800, "A", 2, "5"),
    ];
    await whole.process({ chains: { 1: { startBlock: 0, endBlock: 100, simulate: events } } });
    await split.process({ chains: { 1: { startBlock: 0, endBlock: 12, simulate: events.slice(0, 2) } } });
    await split.process({ chains: { 1: { startBlock: 13, endBlock: 100, simulate: events.slice(2) } } });
    const wholeRows = ordered(await whole.TradeStats_hour.getAll());
    t.expect({
      hours: wholeRows.length,
      splitEqualsWhole: JSON.stringify(ordered(await split.TradeStats_hour.getAll())) === JSON.stringify(wholeRows),
    }).toEqual({ hours: 2, splitEqualsWhole: true });
  });
});
`,
)