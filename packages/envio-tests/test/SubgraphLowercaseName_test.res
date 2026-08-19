// A manifest names its data sources; envio capitalizes contract names for the
// config it stores. A source whose name already starts uppercase hides the
// difference — one that doesn't, like Safe's `crvUSD`, registers a handler
// against a contract the config doesn't hold.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: crvUSD
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
  nonce: BigInt!
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
import { Entity, store } from "@graphprotocol/graph-ts";

export function handlePing(event: any): void {
  let probe = new Entity();
  probe.setBigInt("nonce", event.params.nonce);
  store.set("Probe", "probe", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a data source whose name starts lowercase", () => {
  it("still routes its events", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        // The manifest says crvUSD; envio's config — and so this API — says
        // CrvUSD. The point is that the event still reaches the mapping.
        1: { simulate: [{ contract: "CrvUSD", event: "Ping", params: { nonce: 7n } }] },
      },
    });

    t.expect(await indexer.Probe.getOrThrow("probe")).toEqual({ id: "probe", nonce: 7n });
  });
});
`,
)
