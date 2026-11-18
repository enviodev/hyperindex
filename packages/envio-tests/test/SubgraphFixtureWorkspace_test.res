// `InternalTestIndexer.fromSubgraph` writes each fixture's project to a
// workspace under os.tmpdir() and never removed one: 25.7k of them (478 MB)
// had piled up on one machine. A parse-only fixture's workspace is now removed
// once the parse is done, and one that runs tests is removed after them.
open Vitest

@module("node:fs") external existsSync: string => bool = "existsSync"

let manifest = `
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
        - Post
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: Published(string)
          handler: handlePublished
      file: ./src/registry.ts
`

let schema = `
type Post @entity {
  id: ID!
}
`

let files = Dict.fromArray([
  (
    "abis/Registry.json",
    `[{"type":"event","name":"Published","anonymous":false,"inputs":[{"name":"hash","type":"string","indexed":false}]}]`,
  ),
])

let mappings = Dict.fromArray([
  (
    "src/registry.ts",
    `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handlePublished(event: any): void {
  store.set("Post", event.params.hash, new Entity());
}
`,
  ),
])

let ranTests: ref<option<string>> = ref(None)

describe("a fixture that runs tests", () => {
  let {workspace} = InternalTestIndexer.fromSubgraph(
    ~manifest,
    ~schema,
    ~files,
    ~mappings,
    // The mapping is loaded from the workspace while the test runs.
    ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("the fixture's own test", () => {
  it("indexes with the mapping written to its workspace", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Registry", event: "Published", params: { hash: "a" } }] } },
    });
    t.expect(await indexer.Post.getAll()).toEqual([{ id: "a" }]);
  });
});
`,
  )
  ranTests := workspace
})

describe("fromSubgraph's workspace", () => {
  it("is removed once a parse-only fixture has parsed", t => {
    let {workspace} = InternalTestIndexer.fromSubgraph(~manifest, ~schema, ~files, ~mappings)
    t.expect(workspace->Option.map(existsSync)).toEqual(Some(false))
  })

  it("is removed after the tests of a fixture that runs them", t => {
    t.expect(ranTests.contents->Option.map(existsSync)).toEqual(Some(false))
  })
})
