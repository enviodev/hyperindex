// A library written only for AssemblyScript has no JavaScript entry: as-base64's
// package.json names no `main`, and asc finds `assembly/index.ts` by itself. Node
// stopped at "Cannot find package .../as-base64/index.js", so nouns-builder and
// fastlane never loaded. The resolver falls back to what asc would load.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Decoded
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/token.ts
`,
  ~schema=`
type Decoded @entity {
  id: ID!
  values: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "node_modules/as-base64/package.json",
      `{"name":"as-base64","version":"0.2.0","types":"assembly/index.ts"}`,
    ),
    (
      "node_modules/as-base64/assembly/index.ts",
      `
export function decode(input: string): Uint8Array {
  let out = new Uint8Array(input.length);
  for (let i: i32 = 0; i < input.length; i++) {
    out[i] = (input.charCodeAt(i) + 1) as u8;
  }
  return out;
}
`,
    ),
    (
      "node_modules/as-base64/assembly/shout.ts",
      `export function shout(text: string): string { return text.toUpperCase(); }`,
    ),
    (
      "node_modules/@scope/as-only/package.json",
      `{"name":"@scope/as-only","version":"1.0.0","ascMain":"lib/main.ts"}`,
    ),
    (
      "node_modules/@scope/as-only/lib/main.ts",
      `export function twice(value: i32): i32 { return value * 2; }`,
    ),
    (
      "src/token.ts",
      `
import { Entity, ethereum, store, Value } from "@graphprotocol/graph-ts";
import { decode } from "as-base64";
import { shout } from "as-base64/assembly/shout";
import { twice } from "@scope/as-only";

export function handlePing(event: ethereum.Event): void {
  let bytes = decode("HAL");
  let entity = new Entity();
  entity.setString("values", bytes[0].toString() + ":" + shout("ok") + ":" + twice(21).toString());
  store.set("Decoded", "1", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an AssemblyScript-only library", () => {
  it("resolves to assembly/index.ts, a subpath and ascMain", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Token",
              event: "Ping",
              params: { amount: 1n },
              block: { number: 10 },
            },
          ],
        },
      },
    });
    t.expect(await indexer.Decoded.getAll()).toEqual([{ id: "1", values: "73:OK:42" }]);
  });
});
`,
)
