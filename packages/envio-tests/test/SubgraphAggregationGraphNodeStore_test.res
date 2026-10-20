// graph-node's own aggregation store test
// (store/test-store/tests/postgres/aggregation.rs, `simple`): its schema, its
// data rows (two tokens at minutes 30, 40, 65 and 121) and its expected hourly
// rows — sums, a sum of squares and a sum of products as expressions, max,
// first, last and a cumulative total, grouped by an entity reference with a
// Bytes id — plus an ungrouped aggregation over the same source. Ids are
// graph-node's for generated ones (graph/src/components/store/entity_cache.rs
// SeqGenerator::id); the store test sets its own.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.1.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Feed
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Feed
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities:
        - Data
      abis:
        - name: Feed
          file: ./abis/Feed.json
      eventHandlers:
        - event: Point(uint8,uint256,uint256)
          handler: handlePoint
      file: ./src/feed.ts
`,
  ~schema=`
type Token @entity {
  id: Bytes!
  name: String!
}

type Data @entity(timeseries: true) {
  id: Int8!
  timestamp: Timestamp!
  token: Token!
  price: BigDecimal!
  amount: BigDecimal!
}

type Stats @aggregation(intervals: ["day", "hour"], source: "Data") {
  id: Int8!
  timestamp: Timestamp!
  token: Token!
  sum: BigDecimal! @aggregate(fn: "sum", arg: "price")
  sum_sq: BigDecimal! @aggregate(fn: "sum", arg: "price * price")
  max: BigDecimal! @aggregate(fn: "max", arg: "amount")
  first: BigDecimal @aggregate(fn: "first", arg: "amount")
  last: BigDecimal! @aggregate(fn: "last", arg: "amount")
  value: BigDecimal! @aggregate(fn: "sum", arg: "price * amount")
  totalValue: BigDecimal! @aggregate(fn: "sum", arg: "price * amount", cumulative: true)
}

type TotalStats @aggregation(intervals: ["hour"], source: "Data") {
  id: Int8!
  timestamp: Timestamp!
  max: BigDecimal! @aggregate(fn: "max", arg: "price")
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Feed.json",
      `[{"type":"event","name":"Point","anonymous":false,"inputs":[{"name":"token","type":"uint8","indexed":false},{"name":"price","type":"uint256","indexed":false},{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/feed.ts",
      `
import { BigDecimal, Bytes, Entity, Value, store } from "@graphprotocol/graph-ts";

export function handlePoint(event: any): void {
  let token = Bytes.fromI32(event.params.token);
  let tokenEntity = new Entity();
  tokenEntity.set("id", Value.fromBytes(token));
  tokenEntity.setString("name", "Token" + event.params.token.toString());
  store.set("Token", token.toHexString(), tokenEntity);

  let data = new Entity();
  data.set("token", Value.fromBytes(token));
  data.setBigDecimal("price", new BigDecimal(event.params.price));
  data.setBigDecimal("amount", new BigDecimal(event.params.amount));
  store.set("Data", "auto", data);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const point = (block: number, minute: number, token: number, price: number, amount: number) => ({
  contract: "Feed",
  event: "Point",
  params: { token: BigInt(token), price: BigInt(price), amount: BigInt(amount) },
  block: { number: block, timestamp: minute * 60 },
});

const plain = (row: any) =>
  Object.fromEntries(
    Object.entries(row).map(([key, value]: [string, any]) => [
        key,
        value instanceof Date ? value.getTime() / 1000 : value === null || value === undefined ? value : String(value),
      ]),
  );
const order = (a: any, b: any) => (a.timestamp === b.timestamp ? (a.token_id < b.token_id ? -1 : 1) : a.timestamp - b.timestamp);

describe("graph-node's aggregation store test", () => {
  it("rolls up the same hourly rows", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 10,
          simulate: [
            point(1, 30, 1, 1, 10),
            point(1, 30, 2, 1, 1),
            point(2, 40, 1, 2, 2),
            point(2, 40, 2, 2, 20),
            point(3, 65, 1, 3, 30),
            point(3, 65, 2, 3, 3),
            point(4, 121, 1, 4, 4),
            point(4, 121, 2, 4, 40),
          ],
        },
      },
    });
    // graph-node's SeqGenerator ids: the block above 32 bits, the block's
    // sequence below; an aggregation row takes its group's largest.
    const id = (block: number, sequence: number) => String((BigInt(block) << 32n) + BigInt(sequence));
    const token1 = "0x01000000";
    const token2 = "0x02000000";
    t.expect({
      hour: (await indexer.Stats_hour.getAll()).sort(order).map(plain),
      day: await indexer.Stats_day.getAll(),
      total: (await indexer.TotalStats_hour.getAll()).sort(order).map(plain),
    }).toEqual({
      hour: [
        { id: id(2, 0), timestamp: 0, token_id: token1, sum: "3", sum_sq: "5", max: "10", first: "10", last: "2", value: "14", totalValue: "14" },
        { id: id(2, 1), timestamp: 0, token_id: token2, sum: "3", sum_sq: "5", max: "20", first: "1", last: "20", value: "41", totalValue: "41" },
        { id: id(3, 0), timestamp: 3600, token_id: token1, sum: "3", sum_sq: "9", max: "30", first: "30", last: "30", value: "90", totalValue: "104" },
        { id: id(3, 1), timestamp: 3600, token_id: token2, sum: "3", sum_sq: "9", max: "3", first: "3", last: "3", value: "9", totalValue: "50" },
      ],
      day: [],
      total: [
        { id: id(2, 1), timestamp: 0, max: "2" },
        { id: id(3, 1), timestamp: 3600, max: "3" },
      ],
    });
  });
});
`,
)
