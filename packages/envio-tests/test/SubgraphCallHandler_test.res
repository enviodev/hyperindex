// A call handler runs for a successful call to the data source's address whose
// input starts with its function's selector. The mapping gets an
// `ethereum.Call`: the immediate caller, the called contract, the transaction
// and block, and the inputs and outputs decoded against the ABI.
//
// graph-node orders the triggers of a block by transaction — a transaction's
// logs first, then its calls in trace order — so a call handler sees the state
// its own transaction's events left, and a later transaction's events come
// after it. The simulate source feeds the same items a trace fetch produces.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Staking
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Staking
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Trace
      abis:
        - name: Staking
          file: ./abis/Staking.json
      callHandlers:
        - function: stake(uint256,address)
          handler: handleStake
        - function: stake(uint256,address)
          handler: handleShadowed
        - function: unstake(uint256)
          handler: handleUnstake
      eventHandlers:
        - event: Staked(uint256)
          handler: handleStaked
      file: ./src/staking.ts
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
      "abis/Staking.json",
      `[
        {"type":"event","name":"Staked","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]},
        {"type":"function","name":"stake","stateMutability":"nonpayable","inputs":[{"name":"amount","type":"uint256"},{"name":"to","type":"address"}],"outputs":[{"name":"shares","type":"uint256"}]},
        {"type":"function","name":"unstake","stateMutability":"nonpayable","inputs":[{"name":"amount","type":"uint256"}],"outputs":[]}
      ]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/staking.ts",
      `
import { BigInt, Entity, ethereum, store } from "@graphprotocol/graph-ts";

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

export function handleStaked(event: any): void {
  record("event Staked " + event.params.amount.toString());
}

export function handleStake(call: ethereum.Call): void {
  record(
    "call stake " +
      call.inputValues[0].value.toBigInt().toString() +
      " to " + call.inputValues[1].value.toAddress().toHexString() +
      " -> " + call.outputValues[0].value.toBigInt().toString() +
      " by " + call.from.toHexString() +
      " on " + call.to.toHexString() +
      " in " + call.block.number.toString() +
      " tx " + call.transaction.hash.toHexString() +
      " from " + call.transaction.from.toHexString()
  );
}

export function handleShadowed(call: ethereum.Call): void {
  record("shadowed");
}

export function handleUnstake(call: ethereum.Call): void {
  record("call unstake " + call.inputValues[0].value.toBigInt().toString() + " " + call.inputValues.length.toString() + " " + call.outputValues.length.toString());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { encodeAbiParameters, encodeFunctionData, parseAbi, toFunctionSelector } from "viem";

const staking = "0x1111111111111111111111111111111111111111";
const abi = parseAbi([
  "function stake(uint256 amount, address to) returns (uint256 shares)",
  "function unstake(uint256 amount)",
]);

const callParams = (data: string, output: string, from: string) => ({
  callInput: data,
  callOutput: output,
  callFrom: from,
  callValue: 0n,
  callGasUsed: 21000n,
});

const selectorOf = (signature: string) => toFunctionSelector(signature).slice(2);

const user = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const router = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const recipient = "0xcccccccccccccccccccccccccccccccccccccccc";
const hash1 = "0x" + "11".repeat(32);
const hash2 = "0x" + "22".repeat(32);

describe("call handlers", () => {
  it("run in transaction order among logs, with the call decoded", async (t) => {
    const indexer = createTestIndexer();
    const stakeName = "__envio_call_" + selectorOf("stake(uint256,address)") + "_stake";
    const unstakeName = "__envio_call_" + selectorOf("unstake(uint256)") + "_unstake";

    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            // Transaction 3's event, with an earlier transaction's call after it
            // in the array: the order is the block's, not the array's.
            { contract: "Staking", event: "Staked", params: { amount: 3n }, block: { number: 10 }, transaction: { transactionIndex: 3, hash: hash2 }, logIndex: 40 },
            {
              contract: "Staking",
              event: stakeName,
              srcAddress: staking,
              params: callParams(
                encodeFunctionData({ abi, functionName: "stake", args: [5n, recipient] }),
                encodeAbiParameters([{ type: "uint256" }], [50n]),
                router,
              ),
              block: { number: 10 },
              transaction: { transactionIndex: 1, hash: hash1, from: user },
              logIndex: 0,
            },
            { contract: "Staking", event: "Staked", params: { amount: 1n }, block: { number: 10 }, transaction: { transactionIndex: 1, hash: hash1 }, logIndex: 7 },
            {
              contract: "Staking",
              event: unstakeName,
              srcAddress: staking,
              params: callParams(encodeFunctionData({ abi, functionName: "unstake", args: [9n] }), "0x", user),
              block: { number: 10 },
              transaction: { transactionIndex: 3, hash: hash2, from: user },
              logIndex: 0,
            },
          ],
        },
      },
    });

    const traces = await indexer.Trace.getAll();
    const labels = traces.sort((a, b) => Number(a.id) - Number(b.id)).map((trace) => trace.label);
    t.expect(labels).toEqual([
      // Transaction 1: its event, then its call.
      "event Staked 1",
      "call stake 5 to " + recipient + " -> 50 by " + router + " on " + staking + " in 10 tx " + hash1 + " from " + user,
      // Transaction 3: its event, then its call.
      "event Staked 3",
      "call unstake 9 1 0",
    ]);
  });
});
`,
)
