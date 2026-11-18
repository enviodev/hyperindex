// graph-node parses JSON with serde_json built with `arbitrary_precision` and
// without `preserve_order` (Cargo.toml; no indexmap in Cargo.lock), so a
// number's JSONValue payload is its literal text, which `toBigInt`/`toI64`
// parse exactly (runtime/wasm/src/host_exports.rs `json_to_*`), and an
// object's entries come in key order (serde_json's BTreeMap). The shim went
// through JSON.parse: numbers past 2^53 lost digits, `1.50` read back as
// `1.5`, and entries kept insertion order with integer-like keys first.
// xaya/stats-subgraph reads a number's text by flipping its kind to STRING,
// and serialises objects by walking `entries`; ERC-8004 subgraphs read
// `toBigInt()` off feedback files.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.1.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Board
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Board
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Post
      abis:
        - name: Board
          file: ./abis/Board.json
      eventHandlers:
        - event: Posted(string)
          handler: handlePosted
      file: ./src/board.ts
`,
  ~schema=`
type Post @entity {
  id: ID!
  keys: String!
  serialised: String!
  big: BigInt!
  wide: BigInt!
  ratio: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Board.json",
      `[{"type":"event","name":"Posted","anonymous":false,"inputs":[{"name":"body","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/board.ts",
      `
import { BigInt, Entity, JSONValue, JSONValueKind, json, store } from "@graphprotocol/graph-ts";

function serialise(value: JSONValue): string {
  if (value.kind == JSONValueKind.NUMBER) {
    value.kind = JSONValueKind.STRING;
    const text = value.toString();
    value.kind = JSONValueKind.NUMBER;
    return text;
  }
  if (value.kind == JSONValueKind.STRING) return '"' + value.toString() + '"';
  if (value.kind == JSONValueKind.BOOL) return value.toBool() ? "true" : "false";
  if (value.kind == JSONValueKind.ARRAY) {
    const items = value.toArray();
    const parts: string[] = [];
    for (let i = 0; i < items.length; i++) parts.push(serialise(items[i]));
    return "[" + parts.join(",") + "]";
  }
  const object = value.toObject();
  const parts: string[] = [];
  for (let i = 0; i < object.entries.length; i++) {
    parts.push('"' + object.entries[i].key + '":' + serialise(object.entries[i].value));
  }
  return "{" + parts.join(",") + "}";
}

export function handlePosted(event: any): void {
  const body = json.fromString(event.params.body).toObject();
  const keys: string[] = [];
  for (let i = 0; i < body.entries.length; i++) keys.push(body.entries[i].key);
  const entity = new Entity();
  entity.setString("keys", keys.join(","));
  entity.setString("serialised", serialise(body.mustGet("nested")));
  entity.setBigInt("big", body.mustGet("big").toBigInt());
  entity.setBigInt("wide", BigInt.fromI64(body.mustGet("wide").toI64()));
  entity.setString("ratio", body.mustGet("ratio").toF64().toString());
  store.set("Post", event.transaction.hash.toHexString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const body = JSON.stringify({ b: 1, a: 2, "10": 3, "2": 4 }).slice(0, -1)
  + ',"big":123456789012345678901234567890,"wide":9007199254740993,"ratio":1.50'
  + ',"nested":{"z":[1.50,1e3,-0],"Z":"s","é":true}}';

describe("json.fromString", () => {
  it("keeps number literals and orders object entries as graph-node does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Board", event: "Posted", params: { body } }] } },
    });

    t.expect((await indexer.Post.getAll()).map(({ id, ...post }: any) => post)).toEqual([
      {
        keys: "10,2,a,b,big,nested,ratio,wide",
        serialised: '{"Z":"s","z":[1.50,1e3,-0],"é":true}',
        big: 123456789012345678901234567890n,
        wide: 9007199254740993n,
        ratio: "1.5",
      },
    ]);
  });
});
`,
)
