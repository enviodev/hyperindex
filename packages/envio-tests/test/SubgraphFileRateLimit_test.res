// A file data source whose gateways all answered 429 was skipped after
// ENVIO_SUBGRAPH_FILE_ATTEMPTS rounds as if the file weren't there
// (HandProtocol: three RoundMetadata files lost while public gateways
// rate-limited the run). A 429 says "slow down", not "no such file":
// graph-node's polling monitor backs off and asks again after an error as
// after a miss (core/src/polling_monitor/mod.rs), and only a timeout counts as
// "not available" (core/src/polling_monitor/ipfs_service.rs). A file is now
// given up as missing only after that many rounds every gateway said 404;
// failures that asking again can mend are asked again, with backoff, for
// ENVIO_SUBGRAPH_IPFS_TIMEOUT_MS, the budget `ipfs.cat` has.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.7
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
        - Post
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Published(string)
          handler: handlePublished
      file: ./src/registry.ts
templates:
  - kind: file/ipfs
    name: Metadata
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Meta
      handler: handleMetadata
      file: ./src/registry.ts
`,
  ~schema=`
type Post @entity {
  id: ID!
}

type Meta @entity {
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
import { Bytes, DataSourceTemplate, Entity, dataSource, store } from "@graphprotocol/graph-ts";

export function handlePublished(event: any): void {
  let hash: string = event.params.hash;
  store.set("Post", hash, new Entity());
  DataSourceTemplate.create("Metadata", [hash]);
}

export function handleMetadata(content: Bytes): void {
  let meta = new Entity();
  meta.setString("content", content.toString());
  store.set("Meta", dataSource.stringParam(), meta);
}
`,
    ),
  ]),
  ~test=`
import { afterAll, beforeAll, describe, it } from "vitest";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { createTestIndexer } from "envio";

const CID = (n: string) => "Qm" + n.padEnd(44, "A");
const asked = new Map<string, number>();
// How many times a CID is answered 429 before its content.
const throttled = new Map([[CID("Busy"), 8], [CID("Jammed"), Infinity]]);

let server: Server;

beforeAll(async () => {
  server = createServer((req, res) => {
    const cid = (req.url ?? "").split("/").pop()!;
    const n = (asked.get(cid) ?? 0) + 1;
    asked.set(cid, n);
    if (cid === CID("Gone")) {
      res.statusCode = 404;
      res.end("not found");
    } else if (n <= (throttled.get(cid) ?? 0)) {
      res.statusCode = 429;
      res.end("Too Many Requests");
    } else {
      res.end("content of " + cid.slice(0, 6));
    }
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  // Two gateways, as a file is missing only when every gateway says so.
  process.env.ENVIO_SUBGRAPH_IPFS_URL = \`http://127.0.0.1:\${port}/a, http://127.0.0.1:\${port}/b\`;
  process.env.ENVIO_SUBGRAPH_FILE_ATTEMPTS = "2";
  process.env.ENVIO_SUBGRAPH_FILE_RETRY_MS = "1";
  process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS = "1";
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

const published = (hash: string, n = 10) => ({
  contract: "Registry",
  event: "Published",
  params: { hash },
  block: { number: n },
});

const run = async (hashes: string[]) => {
  const indexer = createTestIndexer();
  await indexer.process({
    chains: { 1: { simulate: hashes.map((hash, i) => published(hash, 10 + i)) } },
  });
  return {
    meta: (await indexer.Meta.getAll()).sort((a: any, b: any) => a.id.localeCompare(b.id)),
    posts: (await indexer.Post.getAll()).length,
  };
};

describe("a file data source on rate-limited gateways", () => {
  it("keeps asking until a gateway hands the file over", async (t) => {
    t.expect({ ...(await run([CID("Busy")])), asked: asked.get(CID("Busy")) }).toEqual({
      meta: [{ id: CID("Busy"), content: "content of QmBusy" }],
      posts: 1,
      asked: 9,
    });
  });

  it("gives a file up as missing after the attempts in which every gateway said 404", async (t) => {
    t.expect({ ...(await run([CID("Gone")])), asked: asked.get(CID("Gone")) }).toEqual({
      meta: [],
      posts: 1,
      asked: 4,
    });
  });

  it("skips a file still rate-limited when the IPFS timeout runs out, and asks again next time", async (t) => {
    process.env.ENVIO_SUBGRAPH_IPFS_TIMEOUT_MS = "300";
    try {
      const first = await run([CID("Jammed")]);
      const firstAsked = asked.get(CID("Jammed"))!;
      const second = await run([CID("Jammed")]);
      t.expect({
        first,
        second,
        moreThanTheAttempts: firstAsked > 4,
        askedAgain: asked.get(CID("Jammed"))! > firstAsked,
      }).toEqual({
        first: { meta: [], posts: 1 },
        second: { meta: [], posts: 1 },
        moreThanTheAttempts: true,
        askedAgain: true,
      });
    } finally {
      delete process.env.ENVIO_SUBGRAPH_IPFS_TIMEOUT_MS;
    }
  });
});
`,
)
