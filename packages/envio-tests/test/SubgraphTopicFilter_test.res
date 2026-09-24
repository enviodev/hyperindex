// `topic1`–`topic3` narrow an event handler to logs whose indexed parameters
// match. They become the handler's `where`, which the source query applies —
// a simulated event skips that query, so this covers the handler running with
// its filter in place.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.2.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Received
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
          topic2:
            - "0x000000000000000000000000bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      file: ./src/token.ts
`,
  ~schema=`
type Received @entity {
  id: ID!
  value: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Transfer","anonymous":false,"inputs":[{"name":"from","type":"address","indexed":true},{"name":"to","type":"address","indexed":true},{"name":"value","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

export function handleTransfer(event: any): void {
  let received = new Entity();
  let value: BigInt = event.params.value;
  received.setString("id", value.toString());
  received.setBigInt("value", value);
  store.set("Received", value.toString(), received);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const transfer = (to: string, value: bigint) => ({
  contract: "Token",
  event: "Transfer",
  params: { from: "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", to, value },
});

describe("a topic-filtered event handler", () => {
  it("runs for a log whose indexed parameter matches", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [transfer("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1n)],
        },
      },
    });

    t.expect(await indexer.Received.getAll()).toEqual([{ id: "1", value: 1n }]);
  });
});
`,
)
