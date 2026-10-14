// A block handler with `filter: {kind: call}` runs once per call to the data
// source's address, after every log and call handler of its block, and gets the
// block the call was in. A call handler that creates a template registers it
// like an event handler does: the new address's events are indexed from there.
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
      callHandlers:
        - function: deploy(address)
          handler: handleDeploy
      eventHandlers:
        - event: Touched(uint256)
          handler: handleTouched
      blockHandlers:
        - handler: handleCallToFactory
          filter:
            kind: call
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
      `[
        {"type":"event","name":"Touched","anonymous":false,"inputs":[{"name":"n","type":"uint256","indexed":false}]},
        {"type":"function","name":"deploy","stateMutability":"nonpayable","inputs":[{"name":"pool","type":"address"}],"outputs":[]},
        {"type":"function","name":"poke","stateMutability":"nonpayable","inputs":[],"outputs":[]}
      ]`,
    ),
    (
      "abis/Pool.json",
      `[{"type":"event","name":"Swapped","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/factory.ts",
      `
import { DataSourceTemplate, Entity, ethereum, store } from "@graphprotocol/graph-ts";

function record(label: string): void {
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

export function handleTouched(event: any): void {
  record("event Touched " + event.params.n.toString());
}

export function handleDeploy(call: ethereum.Call): void {
  let pool = call.inputValues[0].value.toAddress();
  DataSourceTemplate.create("Pool", [pool.toHexString()]);
  record("call deploy " + pool.toHexString());
}

export function handleCallToFactory(block: ethereum.Block): void {
  record("block " + block.number.toString() + " " + block.hash.toHexString() + " " + block.timestamp.toString());
}
`,
    ),
    (
      "src/pool.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

export function handleSwapped(event: any): void {
  let trace = new Entity();
  trace.setString("label", "pool swapped " + event.params.amount.toString());
  store.set("Trace", "swap-" + event.block.number.toString(), trace);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { encodeFunctionData, parseAbi, toFunctionSelector } from "viem";

const factory = "0x1111111111111111111111111111111111111111";
const pool = "0x3333333333333333333333333333333333333333";
const abi = parseAbi(["function deploy(address pool)", "function poke()"]);
const selectorOf = (signature: string) => toFunctionSelector(signature).slice(2);
const hashOf = (n: number) => "0x" + n.toString(16).padStart(64, "0");

const call = (data: string, transactionIndex: number, name: string) => ({
  contract: "Factory",
  event: name,
  srcAddress: factory,
  params: { callInput: data, callOutput: "0x", callFrom: "0x" + "aa".repeat(20), callValue: 0n, callGasUsed: 1n },
  block: { number: 10, hash: hashOf(10), timestamp: 1_000 },
  transaction: { transactionIndex, hash: hashOf(100 + transactionIndex) },
  logIndex: 0,
});

describe("block handlers filtered by call", () => {
  it("run once per call after the block's logs and calls, and a call handler registers a template", async (t) => {
    const indexer = createTestIndexer();
    const deploy = "__envio_call_" + selectorOf("deploy(address)") + "_deploy";

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            call(encodeFunctionData({ abi, functionName: "deploy", args: [pool] }), 2, deploy),
            // The same call, as the block handler's trigger.
            { ...call(encodeFunctionData({ abi, functionName: "deploy", args: [pool] }), 2, "__envio_call_any"), logIndex: 1 },
            { contract: "Factory", event: "Touched", params: { n: 1n }, block: { number: 10, hash: hashOf(10), timestamp: 1_000 }, transaction: { transactionIndex: 5 }, logIndex: 3 },
            // The pool exists from block 10 on.
            { contract: "Pool", event: "Swapped", srcAddress: pool, params: { amount: 7n }, block: { number: 12 }, logIndex: 1 },
          ],
        },
      },
    });

    const traces = await indexer.Trace.getAll();
    t.expect(traces.map((trace) => trace.label).sort()).toEqual([
      "block 10 " + hashOf(10) + " 1000",
      "call deploy " + pool,
      "event Touched 1",
      "pool swapped 7",
    ]);
    const ordered = traces.filter((trace) => !trace.id.startsWith("swap-")).sort((a, b) => Number(a.id) - Number(b.id));
    t.expect(ordered.map((trace) => trace.label.split(" ")[0])).toEqual(["call", "event", "block"]);
  });
});
`,
)
