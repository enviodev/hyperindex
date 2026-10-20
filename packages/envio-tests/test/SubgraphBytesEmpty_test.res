// graph-ts' `ByteArray.empty()` is `ByteArray.fromI32(0)` and `Bytes.empty()`
// is that cast (common/collections.ts, every release since 0.27): four zero
// bytes, not none. The shim returned an empty array, so a field a mapping
// defaults with `Bytes.empty()` (148 files in 2025-26 subgraphs, e.g.
// `metrics.poolId = Bytes.empty()`) stored `0x` where graph-node stores
// `0x00000000`.
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
        - Metrics
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Synced(uint256)
          handler: handleSynced
      file: ./src/pool.ts
`,
  ~schema=`
type Metrics @entity {
  id: ID!
  poolId: Bytes!
  described: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Synced","anonymous":false,"inputs":[{"name":"reserve","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/pool.ts",
      `
import { ByteArray, Bytes, Entity, store } from "@graphprotocol/graph-ts";

export function handleSynced(event: any): void {
  let metrics = new Entity();
  metrics.setBytes("poolId", Bytes.empty());
  metrics.setString(
    "described",
    [Bytes.empty().length.toString(), ByteArray.empty().toHexString()].join(","),
  );
  store.set("Metrics", "m", metrics);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Bytes.empty()", () => {
  it("is four zero bytes, as graph-ts builds it", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Pool", event: "Synced", params: { reserve: 1n } }] } },
    });
    const [metrics] = await indexer.Metrics.getAll();
    t.expect({
      poolId: Buffer.from(metrics.poolId).toString("hex"),
      described: metrics.described,
    }).toEqual({ poolId: "00000000", described: "4,0x00000000" });
  });
});
`,
)
