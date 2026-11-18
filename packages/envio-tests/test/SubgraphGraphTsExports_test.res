// graph-ts declares Timestamp and Int8 as AssemblyScript type aliases, which asc
// erases, but the JavaScript made of a mapping still imports them by name: xmtp's
// `import { Timestamp } from "@graphprotocol/graph-ts"` was a link error. The
// shim exports the rest of graph-ts 0.38's names too (Felt, TypeId, id_of_type,
// the NEAR/Cosmos/Starknet namespaces).
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
      "src/token.ts",
      `
import { Bytes, Entity, ethereum, Felt, Int8, store, Timestamp, TypeId, id_of_type } from "@graphprotocol/graph-ts";

function seconds(at: Timestamp): Int8 {
  return at / 1000;
}

export function handlePing(event: ethereum.Event): void {
  let entity = new Entity();
  let felt = new Felt(Bytes.fromHexString("0x0100"));
  entity.setString(
    "values",
    seconds(5000).toString() + ":" + id_of_type(TypeId.ArrayString).toString() + ":" + felt.intoBigInt().toString(),
  );
  store.set("Decoded", "1", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("graph-ts 0.38 exports", () => {
  it("imports type aliases by name, and reads TypeId and Felt", async (t) => {
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
    t.expect(await indexer.Decoded.getAll()).toEqual([{ id: "1", values: "5:18:256" }]);
  });
});
`,
)
