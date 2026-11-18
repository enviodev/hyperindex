// A data source created in a block runs its triggers of that block after the
// block's own, and among them graph-node's trigger order holds: calls and logs
// by transaction, a transaction's logs before its calls
// (chain/ethereum/src/trigger.rs, `impl Ord for EthereumTrigger`). A call to
// the new data source is its trigger like a log of it is, so it waits for the
// creating round too.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.8
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Factory
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Factory
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Trace
      abis:
        - name: Factory
          file: ./abis/Factory.json
      eventHandlers:
        - event: Created(address)
          handler: handleCreated
      file: ./src/factory.ts
templates:
  - kind: ethereum/contract
    name: Pool
    network: mainnet
    source:
      abi: Pool
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Trace
      abis:
        - name: Pool
          file: ./abis/Pool.json
      eventHandlers:
        - event: Swapped(uint256)
          handler: handleSwapped
      callHandlers:
        - function: swap()
          handler: handleSwap
      file: ./src/pool.ts
`,
  ~schema=`
type Trace @entity {
  id: ID!
  label: String!
}
type Counter @entity {
  id: ID!
  n: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Factory.json",
      `[{"type":"event","name":"Created","anonymous":false,"inputs":[{"name":"pool","type":"address","indexed":false}]}]`,
    ),
    (
      "abis/Pool.json",
      `[
        {"type":"event","name":"Swapped","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]},
        {"type":"function","name":"swap","stateMutability":"nonpayable","inputs":[],"outputs":[]}
      ]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/record.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function record(label: string): void {
  let counter = store.get("Counter", "c");
  let n: i32 = 0;
  if (counter != null) n = counter.getI32("n");
  let next = new Entity();
  next.setI32("n", n + 1);
  store.set("Counter", "c", next);
  let trace = new Entity();
  trace.setString("label", label);
  store.set("Trace", n.toString(), trace);
}
`,
    ),
    (
      "src/factory.ts",
      `
import { DataSourceTemplate } from "@graphprotocol/graph-ts";
import { record } from "./record";

export function handleCreated(event: any): void {
  DataSourceTemplate.create("Pool", [event.params.pool.toHexString()]);
  record("created");
}
`,
    ),
    (
      "src/pool.ts",
      `
import { ethereum } from "@graphprotocol/graph-ts";
import { record } from "./record";

export function handleSwapped(event: any): void {
  record("swapped " + event.params.amount.toString());
}

export function handleSwap(call: ethereum.Call): void {
  record("called");
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { encodeFunctionData, parseAbi, toFunctionSelector } from "viem";

const pool = "0x3333333333333333333333333333333333333333";
const hashOf = (n: number) => "0x" + n.toString(16).padStart(64, "0");
const block = { number: 10, hash: hashOf(10), timestamp: 1_000 };

describe("a call handler of a data source created in the call's block", () => {
  it("runs after the block's own triggers, among the new data source's by transaction", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            // Created after the pool's own triggers of the block, which still run in
            // the round after it.
            { contract: "Factory", event: "Created", params: { pool }, block, transaction: { transactionIndex: 5 }, logIndex: 10 },
            {
              contract: "Pool",
              event: "__envio_call_" + toFunctionSelector("swap()").slice(2) + "_swap",
              srcAddress: pool,
              params: {
                callInput: encodeFunctionData({ abi: parseAbi(["function swap()"]), functionName: "swap" }),
                callOutput: "0x",
                callFrom: "0x" + "aa".repeat(20),
                callValue: 0n,
                callGasUsed: 1n,
              },
              block,
              transaction: { transactionIndex: 2, hash: hashOf(102) },
              logIndex: 0,
            },
            { contract: "Pool", event: "Swapped", srcAddress: pool, params: { amount: 1n }, block, transaction: { transactionIndex: 2 }, logIndex: 4 },
            { contract: "Pool", event: "Swapped", srcAddress: pool, params: { amount: 2n }, block, transaction: { transactionIndex: 9 }, logIndex: 20 },
          ],
        },
      },
    });

    const traces = await indexer.Trace.getAll();
    t.expect(traces.sort((a, b) => Number(a.id) - Number(b.id)).map((trace) => trace.label)).toEqual([
      "created",
      "swapped 1",
      "called",
      "swapped 2",
    ]);
  });
});
`,
)
