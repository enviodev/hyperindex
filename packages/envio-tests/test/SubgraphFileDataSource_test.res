// File data sources (specVersion 0.0.7): `DataSourceTemplate.create("X", [cid])`
// for a `file/ipfs` template runs the template's handler with the file's bytes,
// once per file and context, in isolation (only the entities it lists, none of
// the chain's), and skips it when the file never arrives.
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
  - kind: file/ipfs
    name: Lines
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Meta
      handler: handleLines
      file: ./src/registry.ts
  - kind: file/arweave
    name: Tx
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Meta
      handler: handleTx
      file: ./src/registry.ts
  - kind: file/ipfs
    name: Parent
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Meta
      handler: handleParent
      file: ./src/registry.ts
  - kind: file/ipfs
    name: Flagless
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Meta
      handler: handleFlagless
      file: ./src/registry.ts
  - kind: file/ipfs
    name: Greedy
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Meta
      handler: handleGreedy
      file: ./src/registry.ts
`,
  ~schema=`
type Post @entity {
  id: ID!
  hash: String!
}

type Meta @entity {
  id: ID!
  content: String!
  tag: String
  sawChain: Boolean!
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
import { Bytes, DataSourceContext, DataSourceTemplate, Entity, JSONValue, Value, dataSource, ipfs, store } from "@graphprotocol/graph-ts";

let runs: i32 = 0;

export function handlePublished(event: any): void {
  let hash: string = event.params.hash;
  let post = new Entity();
  post.setString("hash", hash);
  store.set("Post", hash, post);
  let seed = new Entity();
  seed.setString("content", "seed");
  seed.setBoolean("sawChain", false);
  store.set("Meta", "seed:" + hash, seed);
  if (hash.startsWith("tx:")) {
    DataSourceTemplate.create("Tx", [hash.slice(3)]);
  } else if (hash.startsWith("lines:")) {
    DataSourceTemplate.create("Lines", [hash.slice(6)]);
  } else if (hash.startsWith("parent:")) {
    DataSourceTemplate.create("Parent", [hash.slice(7)]);
  } else if (hash.startsWith("flagless:")) {
    DataSourceTemplate.create("Flagless", [hash.slice(9)]);
  } else if (hash.startsWith("greedy:")) {
    DataSourceTemplate.create("Greedy", [hash.slice(7)]);
  } else if (hash.startsWith("ctx:")) {
    let context = new DataSourceContext();
    context.setString("tag", hash.slice(0, 4));
    DataSourceTemplate.createWithContext("Metadata", [hash.slice(4)], context);
  } else {
    DataSourceTemplate.create("Metadata", [hash]);
  }
}

export function handleMetadata(content: Bytes): void {
  runs = runs + 1;
  let meta = new Entity();
  meta.setString("content", content.toString());
  // The chain handler's Meta under this key is not this data source's to see.
  meta.setBoolean("sawChain", store.get("Meta", "seed:" + dataSource.stringParam()) != null);
  let context = dataSource.context();
  if (context.get("tag") != null) meta.set("tag", context.get("tag")!);
  store.set("Meta", dataSource.stringParam() + "#" + runs.toString(), meta);
}

// A file whose content is the CID of another file.
export function handleParent(content: Bytes): void {
  DataSourceTemplate.create("Metadata", [content.toString()]);
}

export function handleTx(content: Bytes): void {
  let meta = new Entity();
  meta.setString("content", content.toString());
  meta.setBoolean("sawChain", false);
  store.set("Meta", "tx:" + dataSource.stringParam(), meta);
}

export function handleLines(content: Bytes): void {
  ipfs.map(dataSource.stringParam(), "processLine", Value.fromString("u"), ["json"]);
}

export function handleFlagless(content: Bytes): void {
  ipfs.map(dataSource.stringParam(), "processLine", Value.fromString("u"), []);
}

export function processLine(value: JSONValue, userData: Value): void {
  let meta = new Entity();
  meta.setString("content", value.toObject().get("n")!.toString() + userData.toString());
  meta.setBoolean("sawChain", false);
  store.set("Meta", "line:" + value.toObject().get("n")!.toString(), meta);
}

// Not on its entities list.
export function handleGreedy(content: Bytes): void {
  store.set("Post", "x", new Entity());
}
`,
    ),
  ]),
  ~test=`
import { beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";

const g = globalThis as any;
const CID = (n: string) => "Qm" + n.padEnd(44, "A");
const fetched: string[] = [];

beforeAll(() => {
  process.env.ENVIO_SUBGRAPH_RETRY_BACKOFF_MS = "10";
  process.env.ENVIO_SUBGRAPH_FILE_RETRY_MS = "10";
  process.env.ENVIO_SUBGRAPH_FILE_ATTEMPTS = "3";
  process.env.ENVIO_SUBGRAPH_IPFS_URL = "https://gateway.test";
  process.env.ENVIO_SUBGRAPH_ARWEAVE_URL = "https://arweave.test";
  let flaky = 0;
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) => {
    const url = String(input);
    if (!url.startsWith("https://gateway.test/") && !url.startsWith("https://arweave.test/")) return realFetch(input, init);
    fetched.push(url);
    const name = url.split("/").pop()!;
    if (name === CID("Missing")) return Promise.resolve(new Response("nope", { status: 404 }));
    if (name === CID("Shaky")) {
      return Promise.resolve(flaky++ < 1 ? new Response("busy", { status: 503 }) : new Response("flaky content"));
    }
    if (name === CID("Parent")) return Promise.resolve(new Response(CID("Kid")));
    if (name === CID("Lines")) return Promise.resolve(new Response('{"n":"a"}\\n\\n{"n":"b"}\\n'));
    if (url.startsWith("https://arweave.test/")) return Promise.resolve(new Response("from arweave " + name));
    return Promise.resolve(new Response("content of " + name.slice(0, 6)));
  };
});

const published = (hash: string, n = 10) => ({
  contract: "Registry",
  event: "Published",
  params: { hash },
  block: { number: n },
});

// The chain handler's own Meta rows (the isolation probe) aren't the files' output.
const files = async (indexer: any) =>
  (await indexer.Meta.getAll())
    .filter((meta: any) => !meta.id.startsWith("seed:"))
    // The handler's run counter is module state shared by the tests; the file is what matters.
    .map((meta: any) => ({ ...meta, id: meta.id.replace(/#\\d+$/, "#n") }))
    .sort((a: any, b: any) => a.id.localeCompare(b.id));

describe("file data sources", () => {
  it("runs the handler with the file's bytes, from the configured gateway", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published(CID("Uno"))] } } });
    t.expect(await files(indexer)).toEqual([
      { id: CID("Uno") + "#n", content: "content of QmUnoA", tag: null, sawChain: false },
    ]);
    t.expect(fetched).toContain("https://gateway.test/ipfs/" + CID("Uno"));
  });

  it("runs it once per file, however often the file is created", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [published(CID("Twice"), 10), published(CID("Twice"), 11), published(CID("Another"), 12)] } },
    });
    t.expect((await files(indexer)).map((meta: any) => meta.id)).toEqual(
      [CID("Twice") + "#n", CID("Another") + "#n"].sort(),
    );
    t.expect((await indexer.Post.getAll()).length).toBe(2);
  });

  it("hands the handler the context it was created with", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published("ctx:" + CID("Ctx"))] } } });
    t.expect((await files(indexer)).map((meta: any) => meta.tag)).toEqual(["ctx:"]);
  });

  it("asks a failing gateway again, then runs the handler", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published(CID("Shaky"))] } } });
    t.expect((await files(indexer)).map((meta: any) => meta.content)).toEqual(["flaky content"]);
  });

  it("skips the handler for a file that never arrives, and carries on", async (t) => {
    fetched.length = 0;
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published(CID("Missing")), published(CID("After"), 11)] } } });
    t.expect((await files(indexer)).map((meta: any) => meta.id)).toEqual([CID("After") + "#n"]);
    t.expect((await indexer.Post.getAll()).length).toBe(2);
    t.expect(fetched.filter((url) => url.endsWith(CID("Missing"))).length).toBe(3);
  });

  it("ignores a data source created with something that isn't a CID", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published("not a cid")] } } });
    t.expect(await files(indexer)).toEqual([]);
    t.expect((await indexer.Post.getAll()).length).toBe(1);
  });

  it("reads an Arweave transaction from the Arweave gateway", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published("tx:abc_DEF-123")] } } });
    t.expect((await files(indexer)).map((meta: any) => [meta.id, meta.content])).toEqual([
      ["tx:abc_DEF-123", "from arweave abc_DEF-123"],
    ]);
  });

  it("streams a file's JSON lines to an ipfs.map callback", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published("lines:" + CID("Lines"))] } } });
    t.expect((await files(indexer)).map((meta: any) => [meta.id, meta.content])).toEqual([
      ["line:a", "au"],
      ["line:b", "bu"],
    ]);
  });

  it("runs the data sources a file handler creates", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { simulate: [published("parent:" + CID("Parent"))] } } });
    t.expect((await files(indexer)).map((meta: any) => [meta.id, meta.content])).toEqual([
      [CID("Kid") + "#n", "content of QmKidA"],
    ]);
  });

  it("refuses ipfs.map without the json flag", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(indexer.process({ chains: { 1: { simulate: [published("flagless:" + CID("Lines"))] } } }))
      .rejects.toThrow(/Flags must contain 'json'/);
  });

  it("refuses a handler that writes an entity its manifest entry doesn't list", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(indexer.process({ chains: { 1: { simulate: [published("greedy:" + CID("Greedy"))] } } }))
      .rejects.toThrow(/entity type \`Post\` is not on the 'entities' list for data source \`Greedy\`/);
  });
});
`,
)
