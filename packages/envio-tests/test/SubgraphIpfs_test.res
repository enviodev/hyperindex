// `ipfs.cat` through the public gateway. A file the gateway doesn't have reads
// as null, as on graph-node; a gateway that is failing is asked again, not
// cached as a null for good.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Metadata
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Published(string)
          handler: handlePublished
      file: ./src/registry.ts
`,
  ~schema=`
type Metadata @entity {
  id: ID!
  content: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"Published","anonymous":false,"inputs":[{"name":"hash","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, ipfs, store } from "@graphprotocol/graph-ts";

export function handlePublished(event: any): void {
  let hash: string = event.params.hash;
  let data = ipfs.cat(hash);
  let metadata = new Entity();
  metadata.setString("content", data === null ? "null" : data.toString());
  store.set("Metadata", hash, metadata);
}
`,
    ),
  ]),
  ~test=`
import { beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";

const g = globalThis as any;

beforeAll(() => {
  process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS = "20";
  let flakyFailures = 0;
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) => {
    const url = String(input);
    if (url.endsWith("/ipfs/QmMissing")) return Promise.resolve(new Response("not found", { status: 404 }));
    if (url.endsWith("/ipfs/QmFlaky")) {
      return Promise.resolve(
        flakyFailures++ < 2 ? new Response("busy", { status: 503 }) : new Response("hello"),
      );
    }
    return realFetch(input, init);
  };
});

const published = (hash: string) => ({
  contract: "Registry",
  event: "Published",
  params: { hash },
});

describe("ipfs.cat", () => {
  it("reads a file the gateway doesn't have as null", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published("QmMissing")] } } });
    t.expect(await indexer.Metadata.getAll()).toEqual([{ id: "QmMissing", content: "null" }]);
  });

  it("asks a failing gateway again rather than answering null", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published("QmFlaky")] } } });
    t.expect(await indexer.Metadata.getAll()).toEqual([{ id: "QmFlaky", content: "0x68656c6c6f" }]);
  });
});
`,
)
