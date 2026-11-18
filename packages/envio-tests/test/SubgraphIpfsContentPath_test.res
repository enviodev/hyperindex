// graph-node reads `ipfs.cat`'s argument as a `ContentPath`
// (graph/src/ipfs/content_path.rs): a CID with an optional path, behind `/ipfs/`,
// `ipfs://` or an http(s) gateway URL. Anything else fails to parse, and
// `ipfs.cat` returns null (runtime/wasm/src/module/context.rs). The shim sent
// whatever it got to the gateway: SoulSystem's `ipfs.cat("")` (an empty URI's
// last segment) asked for the gateway's root, which answered 429, and the run
// stalled asking again; a gateway URL was appended to the gateway.
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
        - event: Published(string,string)
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
      `[{"type":"event","name":"Published","anonymous":false,"inputs":[{"name":"key","type":"string","indexed":false},{"name":"hash","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Entity, ipfs, store } from "@graphprotocol/graph-ts";

export function handlePublished(event: any): void {
  let data = ipfs.cat(event.params.hash);
  let metadata = new Entity();
  metadata.setString("content", data === null ? "null" : data.toString());
  store.set("Metadata", event.params.key, metadata);
}
`,
    ),
  ]),
  ~test=`
import { beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";

const g = globalThis as any;
const cid = "QmVkvoPGi9jvvuxsHDVJDgzPEzagBaWSZRYoRDzU244HjZ";
const asked: string[] = [];

beforeAll(() => {
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) => {
    const url = String(input);
    const at = url.indexOf("/ipfs/");
    if (at < 0) return realFetch(input, init);
    const path = url.slice(at + "/ipfs/".length);
    asked.push(path);
    if (path === cid) return Promise.resolve(new Response("root"));
    if (path === cid + "/meta.json") return Promise.resolve(new Response("meta"));
    return Promise.resolve(new Response("busy", { status: 429 }));
  };
});

const published = (key: string, hash: string) => ({
  contract: "Registry",
  event: "Published",
  params: { key, hash },
});

describe("ipfs.cat's content path", () => {
  it("reads what graph-node parses and answers null for the rest, unasked", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            published("empty", ""),
            published("word", "not_a_cid"),
            published("query", cid + "/meta.json?offline=true"),
            published("gateway", "https://example.org/ipfs/" + cid + "/meta.json"),
            published("api", "https://example.org/api/v0/cat?arg=" + cid),
            published("scheme", "ipfs://" + cid),
            published("slashes", "//" + cid + "/"),
          ],
        },
      },
    });
    const rows = await indexer.Metadata.getAll();
    t.expect({
      content: Object.fromEntries(rows.map((row: any) => [row.id, row.content])),
      asked: [...new Set(asked)].sort(),
    }).toEqual({
      content: { empty: "null", word: "null", query: "null", gateway: "meta", api: "root", scheme: "root", slashes: "root" },
      asked: [cid, cid + "/meta.json"],
    });
  });
});
`,
)
