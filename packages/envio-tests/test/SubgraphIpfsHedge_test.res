// IPFS gateways are asked in order, and one that hangs held every file up
// for the whole request deadline (30 s) before the next was asked: an
// ERC-8004 registry (agent0lab/subgraph, vvizardev/erc-8004-subgraph) whose
// files the first gateway sat on committed nothing in three minutes. The next
// gateway is now asked as well once the one before has kept silent for two
// seconds, and the first to hand the file over answers.
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
const cid = "QmVkvoPGi9jvvuxsHDVJDgzPEzagBaWSZRYoRDzU244HjZ";
let silentAborted = false;

beforeAll(() => {
  process.env.ENVIO_SUBGRAPH_IPFS_URL = "https://silent.example/ipfs/,https://quick.example/ipfs/";
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) => {
    const url = String(input);
    if (url.startsWith("https://silent.example/")) {
      return new Promise((_, reject) => {
        init?.signal?.addEventListener("abort", () => {
          silentAborted = true;
          reject(new DOMException("aborted", "AbortError"));
        });
      });
    }
    if (url.startsWith("https://quick.example/")) return Promise.resolve(new Response("hello"));
    return realFetch(input, init);
  };
});

describe("ipfs.cat with a gateway that keeps silent", () => {
  it("asks the next gateway as well and takes the first answer", async (t) => {
    const indexer = createTestIndexer();
    const started = Date.now();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Registry", event: "Published", params: { hash: cid } }] } },
    });
    t.expect({
      rows: await indexer.Metadata.getAll(),
      silentCancelled: silentAborted,
      quick: Date.now() - started < 15000,
    }).toEqual({ rows: [{ id: cid, content: "hello" }], silentCancelled: true, quick: true });
  });
});
`,
)
