// `let result: JsonResult;` declares a class-typed local without a value, and
// asc 0.19.10 compiles it as the null pointer: `result.error = 'none'` writes
// at that offset of address 0 and `return result` hands the caller the same
// address, which reads back what was written (checked against asc's build of
// the same code). DAOhaus' parser builds its results so, and the run stopped
// at the first Poster event. A local whose first use writes one of its fields
// is that null-address object here: one per class, fresh in every trigger as
// graph-node's module memory is.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Poster
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Poster
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.6
      language: wasm/assemblyscript
      entities:
        - Record
      abis:
        - name: Poster
          file: ./abis/Poster.json
      eventHandlers:
        - event: NewPost(string)
          handler: handleNewPost
      file: ./src/poster.ts
`,
  ~schema=`
type Record @entity {
  id: ID!
  error: String!
  title: String
  description: String
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Poster.json",
      `[{"type":"event","name":"NewPost","anonymous":false,"inputs":[{"name":"content","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/parser.ts",
      `
import { Bytes, ByteArray, JSONValue, JSONValueKind, TypedMap, json } from "@graphprotocol/graph-ts";

class JsonStringResult {
  data: string;
  error: string;
}
class JsonResult {
  object: TypedMap<string, JSONValue>;
  error: string;
}

export function getResultFromJson(content: string): JsonResult {
  let result: JsonResult;
  result.error = "none";
  let jsonResult = json.try_fromBytes(changetype<Bytes>(ByteArray.fromUTF8(content)));
  if (jsonResult.isError) {
    result.error = "Failed to parse JSON";
    return result;
  }
  result.object = jsonResult.value.toObject();
  return result;
}

export function getStringFromJson(object: TypedMap<string, JSONValue>, key: string): JsonStringResult {
  let result: JsonStringResult;
  result.error = "none";
  let value = object.get(key);
  if (!value || value.kind != JSONValueKind.STRING) {
    result.error = "Missing valid Poster field: " + key;
    return result;
  }
  result.data = value.toString();
  return result;
}
`,
    ),
    (
      "src/poster.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { getResultFromJson, getStringFromJson } from "./parser";

export function handleNewPost(event: any): void {
  let record = new Entity();
  let result = getResultFromJson(event.params.content);
  record.setString("error", result.error);
  if (result.error == "none") {
    let object = result.object;
    let title = getStringFromJson(object, "title");
    if (title.error == "none") record.setString("title", title.data);
    let description = getStringFromJson(object, "description");
    if (description.error == "none") record.setString("description", description.data);
  }
  store.set("Record", event.logIndex.toString(), record);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a class-typed local declared without a value", () => {
  it("is the null-address object asc writes and reads its fields through", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Poster", event: "NewPost", params: { content: '{"title":"Hello"}' }, logIndex: 1 },
            { contract: "Poster", event: "NewPost", params: { content: "not json" }, logIndex: 2 },
          ],
        },
      },
    });
    t.expect(await indexer.Record.getAll()).toEqual([
      { id: "1", error: "none", title: "Hello", description: null },
      { id: "2", error: "Failed to parse JSON", title: null, description: null },
    ]);
  });
});
`,
)
