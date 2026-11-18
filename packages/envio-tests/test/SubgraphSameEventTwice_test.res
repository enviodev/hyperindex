// Two handlers on one event (swaap-labs/swaap-subgraph-v1 hangs a dozen on
// LOG_CALL): graph-node's `handlers_for_log` returns every handler of the data
// source whose event matches, and runs them in manifest order. The translation
// gave the second its own envio event, which envio refused as one "the indexer
// can't tell apart" from the first.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
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
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Counter
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handleFirst
        - event: Ping(uint256)
          handler: handleSecond
      file: ./src/pool.ts
`,
  ~schema=`
type Counter @entity {
  id: ID!
  trail: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/pool.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";

function append(step: string): void {
  let counter = store.get("Counter", "c");
  const trail = counter == null ? "" : counter.getString("trail") + ",";
  counter = new Entity();
  counter.set("trail", Value.fromString(trail + step));
  store.set("Counter", "c", counter);
}

export function handleFirst(event: any): void {
  append("first:" + event.params.nonce.toString());
}

export function handleSecond(event: any): void {
  append("second:" + event.params.nonce.toString());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const ping = (nonce: bigint) => ({ contract: "Pool", event: "Ping", params: { nonce } });

describe("two handlers on one event", () => {
  it("both run, in manifest order", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [ping(1n), ping(2n)] } } });

    t.expect(await indexer.Counter.getOrThrow("c")).toEqual({
      id: "c",
      trail: "first:1,second:1,first:2,second:2",
    });
  });
});
`,
)
