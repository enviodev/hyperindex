// A cumulative aggregate carries each group's previous bucket forward, so the
// rollup reads every group's carried values. Read one group at a time through
// the sync bridge, a bucket with N groups replayed the handler that crossed its
// end N times, each replay redoing the rollup: graph-node's own aggregation
// example (a group per block number modulo 1000) committed nothing in three
// minutes. The replays run before the mapping, which can't count them, so the
// test compares the same rows rolled up as one group and as one group each.
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
        - event: Traded(string,uint256)
          handler: handleTraded
      file: ./src/market.ts
`,
  ~schema=`
type Trade @entity(timeseries: true) {
  id: Int8!
  timestamp: Timestamp!
  market: String!
  amount: BigInt!
}

type MarketStats @aggregation(intervals: ["hour"], source: "Trade") {
  id: Int8!
  timestamp: Timestamp!
  market: String!
  trades: Int! @aggregate(fn: "count", cumulative: true)
  total: BigInt! @aggregate(fn: "sum", arg: "amount", cumulative: true)
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Market.json",
      `[{"type":"event","name":"Traded","anonymous":false,"inputs":[{"name":"market","type":"string","indexed":false},{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/market.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleTraded(event: any): void {
  let trade = new Entity();
  trade.setString("market", event.params.market);
  trade.setBigInt("amount", event.params.amount);
  store.set("Trade", "ignored", trade);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const hour = 3600 * 500000;
const count = 2000;

const run = async (market: (index: number) => string) => {
  const indexer = createTestIndexer();
  const simulate = Array.from({ length: count }, (_, index) => ({
    contract: "Market",
    event: "Traded",
    params: { market: market(index), amount: 1n },
    block: { number: index + 1, timestamp: hour + (index % 3600) },
  }));
  simulate.push({
    contract: "Market",
    event: "Traded",
    params: { market: "late", amount: 1n },
    block: { number: count + 1, timestamp: hour + 3600 },
  });
  const started = performance.now();
  await indexer.process({ chains: { 1: { startBlock: 0, endBlock: count + 10, simulate } } });
  const elapsed = performance.now() - started;
  const rows = await indexer.MarketStats_hour.getAll();
  return { elapsed, buckets: rows.length, trades: rows.reduce((sum: number, row: any) => sum + row.trades, 0) };
};

describe("a cumulative aggregation over many groups", () => {
  it("rolls a bucket of one group each up about as fast as one group", async (t) => {
    const oneGroup = await run(() => "only");
    const groupEach = await run((index) => "M" + index);
    t.expect({
      oneGroup: oneGroup.buckets + "/" + oneGroup.trades,
      groupEach: groupEach.buckets + "/" + groupEach.trades,
      comparable: groupEach.elapsed < 4 * oneGroup.elapsed + 500 ? true : [groupEach.elapsed, oneGroup.elapsed],
    }).toEqual({ oneGroup: "1/2000", groupEach: "2000/2000", comparable: true });
  });
});
`,
)
