// A monorepo's subgraph imports its shared mapping code as a workspace package —
// enzyme's `@enzymefinance/subgraph-utils` (`packages/utils`, `"main":
// "index.ts"`) — which the install links into node_modules. Without that
// install (one that died on a dead git dependency, a builder that never runs
// one) the name resolved nowhere, and envio would try to fetch it from npm,
// where it isn't, or is someone else's. It now resolves to the workspace's own
// package, as the install would link it.
let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Feed
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Feed
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Added
      abis:
        - name: Feed
          file: ./abis/Feed.json
      eventHandlers:
        - event: PrimitiveAdded(uint256)
          handler: handlePrimitiveAdded
      file: ./src/feed.ts
`

let schema = `
type Added @entity {
  id: ID!
}
`

let abi = `[{"type":"event","name":"PrimitiveAdded","anonymous":false,"inputs":[{"name":"primitive","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Feed.json", abi)]),
  ~projectDir="subgraphs/core",
  ~mappings=Dict.fromArray([
    ("package.json", `{"private":true,"workspaces":["packages/*","subgraphs/*"]}`),
    ("subgraphs/core/package.json", `{"name":"@ws/core","private":true}`),
    ("subgraphs/core/subgraph.yaml", manifest),
    ("subgraphs/core/schema.graphql", schema),
    ("subgraphs/core/abis/Feed.json", abi),
    (
      "packages/utils/package.json",
      `{"name":"@enzymefinance/subgraph-utils","version":"0.0.0","private":true,"main":"index.ts"}`,
    ),
    (
      "packages/utils/index.ts",
      `export * from "./utils/id";
`,
    ),
    (
      "packages/utils/utils/id.ts",
      `
import { BigInt } from "@graphprotocol/graph-ts";

export function primitiveId(value: BigInt): string {
  let id: i32 = value.toI32() * 10;
  return "primitive/" + id.toString();
}
`,
    ),
    (
      "subgraphs/core/src/feed.ts",
      `
import { primitiveId } from "@enzymefinance/subgraph-utils";
import { PrimitiveAdded } from "../generated/Feed/Feed";
import { Added } from "../generated/schema";

export function handlePrimitiveAdded(event: PrimitiveAdded): void {
  new Added(primitiveId(event.params.primitive)).save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a workspace package without an install", () => {
  it("resolves to the workspace's own package", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Feed", event: "PrimitiveAdded", params: { primitive: 4n } }] } },
    });

    t.expect(await indexer.Added.getAll()).toEqual([{ id: "primitive/40" }]);
  });
});
`,
)
