// Preload runs a batch's handlers with their writes thrown away, so every one
// of them read the rollup clock as the last batch left it, saw its block cross
// the end of that clock's bucket and rolled the bucket up again: a batch of
// 5,000 block handlers redid one rollup 5,000 times, and graph-node's
// aggregation example stalled from its second batch on. The rows a rollup
// reads stay in memory once the batch has loaded them, so the time a batch
// takes tells it: a batch after a split run against the same rows indexed in
// one run.
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
  total: BigInt! @aggregate(fn: "sum", arg: "amount")
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
const trades = (from: number, start: number) =>
  Array.from({ length: count }, (_, index) => ({
    contract: "Market",
    event: "Traded",
    params: { market: "M" + (index % 50), amount: 1n },
    block: { number: from + index, timestamp: start + Math.floor(index / 2) },
  }));
const first = trades(1, hour);
const second = trades(count + 1, hour + 3600);
const end = 2 * count + 10;

const timed = async (run: () => Promise<unknown>) => {
  const started = performance.now();
  await run();
  return performance.now() - started;
};

describe("rollups in a batch after the first", () => {
  it("run once per bucket, not once per preloaded handler", async (t) => {
    const whole = createTestIndexer();
    const wholeMs = await timed(() =>
      whole.process({ chains: { 1: { startBlock: 0, endBlock: end, simulate: [...first, ...second] } } }),
    );
    const split = createTestIndexer();
    await split.process({ chains: { 1: { startBlock: 0, endBlock: count, simulate: first } } });
    const secondMs = await timed(() =>
      split.process({ chains: { 1: { startBlock: count + 1, endBlock: end, simulate: second } } }),
    );
    const totals = async (indexer: any) =>
      (await indexer.MarketStats_hour.getAll()).map((row: any) => row.market + "=" + row.total).sort().join(",");
    t.expect({
      same: (await totals(split)) === (await totals(whole)),
      buckets: (await whole.MarketStats_hour.getAll()).length,
      comparable: secondMs < 2 * wholeMs + 500 ? true : [secondMs, wholeMs],
    }).toEqual({ same: true, buckets: 50, comparable: true });
  });
});
`,
)
