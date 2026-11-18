// graph-node hands `dataSource.address()` the data source's address bytes
// (runtime/wasm/src/host_exports.rs `DataSourceDetails`: `ds.address()
// .unwrap_or_default()`): none for a data source without `source.address`, and
// for a file data source its source's text (graph/src/data_source/offchain.rs
// `Source::address`), which `dataSource.stringParam()` decodes back. The shim
// answered a wildcard data source with the emitter's address and refused the
// call in a file data source.
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
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Seen
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
        - Seen
      handler: handleMetadata
      file: ./src/registry.ts
`,
  ~schema=`
type Seen @entity {
  id: ID!
  address: String!
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
  let seen = new Entity();
  seen.setString("address", dataSource.address().toHexString());
  store.set("Seen", "chain", seen);
  DataSourceTemplate.create("Metadata", [event.params.hash]);
}

export function handleMetadata(content: Bytes): void {
  let seen = new Entity();
  seen.setString("address", dataSource.address().toString() + "|" + dataSource.stringParam());
  store.set("Seen", "file", seen);
}
`,
    ),
  ]),
  ~test=`
import { beforeAll, describe, it } from "vitest";
import { createTestIndexer } from "envio";

const g = globalThis as any;
const cid = "QmVkvoPGi9jvvuxsHDVJDgzPEzagBaWSZRYoRDzU244HjZ";

beforeAll(() => {
  process.env.ENVIO_SUBGRAPH_IPFS_URL = "https://gateway.test";
  const realFetch = g.fetch;
  g.fetch = (input: any, init: any) =>
    String(input).startsWith("https://gateway.test/") ? Promise.resolve(new Response("{}")) : realFetch(input, init);
});

describe("dataSource.address()", () => {
  it("is empty without a source address, and the source's text in a file data source", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Registry",
              event: "Published",
              params: { hash: cid },
              srcAddress: "0x2222222222222222222222222222222222222222",
            },
          ],
        },
      },
    });
    const rows = await indexer.Seen.getAll();
    t.expect(Object.fromEntries(rows.map((row: any) => [row.id, row.address]))).toEqual({
      chain: "0x",
      file: cid + "|" + cid,
    });
  });
});
`,
)
