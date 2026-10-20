// graph-ts before 0.22 named the transaction's sixth field `gasUsed`; graph-node
// fills that slot with the transaction's gas limit (`gas_limit` in every
// `AscEthereumTransaction_0_0_*`, chain/ethereum/src/runtime/abi.rs), which
// later graph-ts calls `gasLimit`. Uniswap v3's 2022 mappings store
// `event.transaction.gasUsed` on every Transaction entity, and it read null.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.2
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
      apiVersion: 0.0.4
      language: wasm/assemblyscript
      entities:
        - Transaction
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/token.ts
`,
  ~schema=`
type Transaction @entity {
  id: ID!
  gasUsed: BigInt!
  gasPrice: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handlePing(event: any): void {
  let transaction = new Entity();
  transaction.setBigInt("gasUsed", event.transaction.gasUsed);
  transaction.setBigInt("gasPrice", event.transaction.gasPrice);
  store.set("Transaction", event.transaction.hash.toHexString(), transaction);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a pre-0.22 graph-ts transaction", () => {
  it("reads the gas limit as gasUsed, as graph-node hands it over", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Token",
              event: "Ping",
              params: { nonce: 1n },
              transaction: { hash: "0xcc", gas: 21000n, gasPrice: 9n, gasUsed: 5n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Transaction.getOrThrow("0xcc")).toEqual({ id: "0xcc", gasUsed: 21000n, gasPrice: 9n });
  });
});
`,
)
