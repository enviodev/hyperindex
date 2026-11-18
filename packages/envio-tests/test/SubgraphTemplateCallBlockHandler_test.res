// A template's block handler with `filter: {kind: call}` runs once per call to
// each instance's address, from the block the instance was created in. In that
// block the instance's triggers run after the block's own, and among them
// graph-node's trigger order holds: block triggers, the call-filtered ones
// included, come after every log and call (chain/ethereum/src/trigger.rs,
// `impl Ord for EthereumTrigger`), whatever transaction the call was in.
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
      blockHandlers:
        - handler: handleCallToPool
          filter:
            kind: call
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
import { dataSource, ethereum } from "@graphprotocol/graph-ts";
import { record } from "./record";

export function handleSwapped(event: any): void {
  record("swapped " + event.params.amount.toString());
}

export function handleCallToPool(block: ethereum.Block): void {
  record("called " + dataSource.address().toHexString() + " in block " + block.number.toString());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { encodeFunctionData, parseAbi } from "viem";

const pool = "0x3333333333333333333333333333333333333333";
const hashOf = (n: number) => "0x" + n.toString(16).padStart(64, "0");
const blockOf = (number: number) => ({ number, hash: hashOf(number), timestamp: 1_000 + number });
const swapCall = (number: number, transactionIndex: number) => ({
  contract: "Pool",
  event: "__envio_call_any",
  srcAddress: pool,
  params: {
    callInput: encodeFunctionData({ abi: parseAbi(["function swap()"]), functionName: "swap" }),
    callOutput: "0x",
    callFrom: "0x" + "aa".repeat(20),
    callValue: 0n,
    callGasUsed: 1n,
  },
  block: blockOf(number),
  transaction: { transactionIndex, hash: hashOf(number * 1000 + transactionIndex) },
  logIndex: 0,
});

describe("a call-filtered block handler on a template", () => {
  it("runs for each call to an instance, in its creation block after the instance's logs", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Factory", event: "Created", params: { pool }, block: blockOf(10), transaction: { transactionIndex: 5 }, logIndex: 10 },
            swapCall(10, 2),
            { contract: "Pool", event: "Swapped", srcAddress: pool, params: { amount: 1n }, block: blockOf(10), transaction: { transactionIndex: 9 }, logIndex: 20 },
            swapCall(12, 0),
          ],
        },
      },
    });

    const traces = await indexer.Trace.getAll();
    t.expect(traces.sort((a, b) => Number(a.id) - Number(b.id)).map((trace) => trace.label)).toEqual([
      "created",
      "swapped 1",
      "called " + pool + " in block 10",
      "called " + pool + " in block 12",
    ]);
  });
});
`,
)
