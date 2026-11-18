// graph-ts up to 0.21 named the transaction's sixth field `gasUsed`; graph-node
// fills that slot with the gas limit (chain/ethereum/src/runtime/abi.rs
// `AscEthereumTransaction_0_0_1.gas_limit`), and later graph-ts renamed it
// `gasLimit`. Uniswap v3's original mappings save `event.transaction.gasUsed`
// into a required field, which came out null here.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.2
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Pool
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.4
      language: wasm/assemblyscript
      entities:
        - Transaction
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Swap(uint256)
          handler: handleSwap
      file: ./src/pool.ts
`,
  ~schema=`
type Transaction @entity {
  id: ID!
  gasUsed: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Swap","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/pool.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleSwap(event: any): void {
  let transaction = new Entity();
  transaction.set("gasUsed", Value.fromBigInt(event.transaction.gasUsed));
  store.set("Transaction", event.transaction.hash.toHexString(), transaction);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an old mapping's transaction.gasUsed", () => {
  it("is the gas limit, as graph-node hands it over", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Pool", event: "Swap", params: { amount: 1n }, transaction: { hash: "0xcc", gas: 21000n } },
          ],
        },
      },
    });
    t.expect(await indexer.Transaction.getAll()).toEqual([{ id: "0xcc", gasUsed: 21000n }]);
  });
});
`,
)
