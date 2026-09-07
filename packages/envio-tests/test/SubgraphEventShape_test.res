// `event.block`, `event.transaction` and `event.receipt` are graph-ts shapes,
// not envio's. The names differ — envio's `transactionIndex` is graph-ts' `index`
// and its `gas` is `gasLimit` — and the field selection already asks for the
// block scalars a mapping reads, so the values have to arrive under the names
// the generated code uses.
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
        - Probe
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
          receipt: true
      file: ./src/token.ts
`,
  ~schema=`
type Probe @entity {
  id: ID!
  value: String!
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

function probe(id: string, value: string): void {
  let entity = new Entity();
  entity.setString("value", value);
  store.set("Probe", id, entity);
}

export function handlePing(event: any): void {
  probe("blockHash", event.block.hash.toHexString());
  probe("blockAuthor", event.block.author.toHexString());
  probe("blockGasUsed", event.block.gasUsed.toString());
  probe("blockParent", event.block.parentHash.toHexString());
  probe("blockNumber", event.block.number.toString());

  // graph-ts calls these index and gasLimit; envio decodes them as
  // transactionIndex and gas.
  probe("txIndex", event.transaction.index.toString());
  probe("txGasLimit", event.transaction.gasLimit.toString());
  probe("txHash", event.transaction.hash.toHexString());
  probe("txFrom", event.transaction.from.toHexString());

  probe("receiptStatus", event.receipt.status.toString());
  probe("receiptGasUsed", event.receipt.gasUsed.toString());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("the event graph-ts sees", () => {
  it("carries the block, transaction and receipt under graph-ts names", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Token",
              event: "Ping",
              params: { nonce: 1n },
              block: {
                number: 42,
                hash: "0xaa",
                parentHash: "0xbb",
                miner: "0x2222222222222222222222222222222222222222",
                gasUsed: 7n,
              },
              transaction: {
                transactionIndex: 3,
                hash: "0xcc",
                gas: 21000n,
                from: "0x3333333333333333333333333333333333333333",
                status: 1n,
                gasUsed: 5n,
              },
            },
          ],
        },
      },
    });

    const value = async (id: string) => (await indexer.Probe.getOrThrow(id)).value;

    t.expect({
      blockHash: await value("blockHash"),
      blockAuthor: await value("blockAuthor"),
      blockGasUsed: await value("blockGasUsed"),
      blockParent: await value("blockParent"),
      blockNumber: await value("blockNumber"),
      txIndex: await value("txIndex"),
      txGasLimit: await value("txGasLimit"),
      txHash: await value("txHash"),
      txFrom: await value("txFrom"),
      receiptStatus: await value("receiptStatus"),
      receiptGasUsed: await value("receiptGasUsed"),
    }).toEqual({
      blockHash: "0xaa",
      blockAuthor: "0x2222222222222222222222222222222222222222",
      blockGasUsed: "7",
      blockParent: "0xbb",
      blockNumber: "42",
      txIndex: "3",
      txGasLimit: "21000",
      txHash: "0xcc",
      txFrom: "0x3333333333333333333333333333333333333333",
      receiptStatus: "1",
      receiptGasUsed: "5",
    });
  });
});
`,
)
