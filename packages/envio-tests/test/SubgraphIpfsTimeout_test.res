// graph-node's `ipfs.cat` gives a file `GRAPH_IPFS_TIMEOUT` (60 s by default,
// graph/src/env/mappings.rs) and returns null when no answer came in that time
// (runtime/wasm/src/module/context.rs "Failed ipfs.cat, returning `null`").
// The shim asked a failing gateway again forever, so a mapping whose file every
// gateway refuses (429s from a rate-limited box: SoulSystem,
// RequestNetwork's storage subgraph) never got past that event. A gateway that
// recovers within the budget still answers, and the null isn't cached.
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
const refused = "QmVkvoPGi9jvvuxsHDVJDgzPEzagBaWSZRYoRDzU244HjZ";
let askedForRefused = 0;

beforeAll(() => {
  process.env.ENVIO_SUBGRAPH_IPFS_TIMEOUT_MS = "400";
  process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS = "20";
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) => {
    const url = String(input);
    if (url.endsWith("/ipfs/" + refused)) {
      askedForRefused++;
      return Promise.resolve(new Response("slow down", { status: 429 }));
    }
    return realFetch(input, init);
  };
});

describe("ipfs.cat against gateways that keep refusing", () => {
  it("answers null once graph-node's timeout has passed, and asks again next time", async (t) => {
    const indexer = createTestIndexer();
    const published = { contract: "Registry", event: "Published", params: { hash: refused } };
    await indexer.process({ chains: { 1: { simulate: [published] } } });
    const first = askedForRefused;
    await indexer.process({ chains: { 1: { startBlock: 10, simulate: [{ ...published, block: { number: 10 } }] } } });
    t.expect({
      rows: await indexer.Metadata.getAll(),
      askedAgain: askedForRefused > first,
    }).toEqual({ rows: [{ id: refused, content: "null" }], askedAgain: true });
  });
});
`,
)
