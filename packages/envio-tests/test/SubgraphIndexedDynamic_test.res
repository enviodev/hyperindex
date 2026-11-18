// An indexed string (or bytes, array, tuple) is in the log only as its keccak256
// hash. graph-node hands the mapping `FixedBytes(32)` and graph codegen types the
// getter `Bytes`, so `event.params.username.toHexString()` reads the hash; the
// shim read the parameter as a string and failed with "Ethereum value is not
// bytes" (MezoPay's UsernameRegistry).
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
        - event: Named(indexed string,indexed address)
          handler: handleNamed
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
      `[{"type":"event","name":"Named","anonymous":false,"inputs":[{"name":"username","type":"string","indexed":true},{"name":"owner","type":"address","indexed":true}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { Entity, ethereum, store } from "@graphprotocol/graph-ts";

export function handleNamed(event: ethereum.Event): void {
  let entity = new Entity();
  entity.setString("values", event.parameters[0].value.toBytes().toHexString());
  store.set("Decoded", "1", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const hash = "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8";

describe("an indexed string", () => {
  it("reads as the 32-byte hash its topic carries", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Token",
              event: "Named",
              params: { username: hash, owner: "0x2222222222222222222222222222222222222222" },
              block: { number: 10 },
            },
          ],
        },
      },
    });
    t.expect(await indexer.Decoded.getAll()).toEqual([{ id: "1", values: hash }]);
  });
});
`,
)
