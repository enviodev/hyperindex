// AssemblyScript divides two integers as integers; JavaScript doesn't. Uniswap
// buckets by day with `timestamp / 86400`, then multiplies back — which under
// float division reproduces the timestamp with drift and lands in an Int column.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pair
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pair
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - DayData
      abis:
        - name: Pair
          file: ./abis/Pair.json
      eventHandlers:
        - event: Sync(uint256)
          handler: handleSync
      file: ./src/pair.ts
`,
  ~schema=`
type DayData @entity {
  id: ID!
  dayStart: Int!
  half: Int!
  ratio: BigDecimal!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pair.json",
      `[{"type":"event","name":"Sync","anonymous":false,"inputs":[{"name":"reserve","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/pair.ts",
      `
import { BigDecimal, Entity, store } from "@graphprotocol/graph-ts";

export function handleSync(event: any): void {
  let timestamp = event.params.reserve.toI32();
  let dayID = timestamp / 86400;
  let dayStartTimestamp = dayID * 86400;

  let entity = new Entity();
  entity.setI32("dayStart", dayStartTimestamp);
  // Nested, and with the operands themselves divisions.
  entity.setI32("half", timestamp / (86400 / 2) / 2);
  // A float operand still divides as a float, the way f64 does in AS.
  entity.setBigDecimal("ratio", BigDecimal.fromString((7.5 / 2).toString()));
  store.set("DayData", dayID.toString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("integer division", () => {
  it("truncates the way AssemblyScript does", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Pair", event: "Sync", params: { reserve: 1588712972n } }] },
      },
    });

    // 1588712972 / 86400 = 18387 (truncated), * 86400 = 1588636800.
    const [day] = await indexer.DayData.getAll();
    t.expect({ ...day, ratio: day.ratio.toString() }).toEqual({
      id: "18387",
      dayStart: 1588636800,
      half: 18387,
      ratio: "3.75",
    });
  });
});
`,
)
