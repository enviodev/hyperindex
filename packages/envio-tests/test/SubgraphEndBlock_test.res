// graph-node stops a data source at its `endBlock` and nothing else: the other
// data sources on its network keep indexing (autonolas predict-polymarket
// retires its v1 exchange that way). envio ends whole chains, so the runtime
// has to drop the retired data source's events itself.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.9
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Retired
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
      endBlock: 5
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      blockHandlers:
        - handler: handleBlock
          filter:
            kind: polling
            every: 4
      file: ./src/token.ts
  - kind: ethereum/contract
    name: Current
    network: mainnet
    source:
      address: "0x2222222222222222222222222222222222222222"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/token.ts
`,
  ~schema=`
type Probe @entity {
  id: ID!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { Entity, ethereum, store } from "@graphprotocol/graph-ts";

export function handlePing(event: any): void {
  store.set("Probe", "ping-" + event.params.nonce.toString(), new Entity());
}

export function handleBlock(block: ethereum.Block): void {
  store.set("Probe", "block-" + block.number.toString(), new Entity());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a data source endBlock", () => {
  it("stops that data source's handlers, and only them", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 9,
          simulate: [
            { contract: "Retired", event: "Ping", params: { nonce: 1n }, block: { number: 3 } },
            { contract: "Retired", event: "Ping", params: { nonce: 2n }, block: { number: 6 } },
            { contract: "Current", event: "Ping", params: { nonce: 3n }, block: { number: 7 } },
          ],
        },
      },
    });

    const ids = (await indexer.Probe.getAll()).map((probe) => probe.id).sort();
    t.expect(ids).toEqual(["block-0", "block-4", "ping-1", "ping-3"]);
  });
});
`,
)
