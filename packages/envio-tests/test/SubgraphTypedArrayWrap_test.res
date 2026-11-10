// `Uint8Array.wrap(buffer)`, the AssemblyScript way to view a buffer's bytes
// (soccerverse builds an id from a DataView-written timestamp that way).
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
        - Cast
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Cast @entity {
  id: ID!
  hex: String!
  tail: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { Bytes, Entity, store } from "@graphprotocol/graph-ts";

export function handleNewOwner(event: any): void {
  let buffer = new ArrayBuffer(8);
  let view = new DataView(buffer);
  view.setInt64(0, 258, false);
  let bytes = changetype<Bytes>(Uint8Array.wrap(buffer));
  let tail = Uint8Array.wrap(buffer, 6, 2);
  let cast = new Entity();
  cast.setString("hex", bytes.toHexString());
  cast.setI32("tail", tail[0] * 256 + tail[1]);
  store.set("Cast", "c1", cast);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("Uint8Array.wrap", () => {
  it("views the buffer's bytes", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 1n } }] },
      },
    });

    t.expect(await indexer.Cast.getOrThrow("c1")).toEqual({ id: "c1", hex: "0x0000000000000102", tail: 258 });
  });
});
`,
)
