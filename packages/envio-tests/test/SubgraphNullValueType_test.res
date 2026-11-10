// `history.withdrawableTimestamp = null` (xmtp/subgraphs, settlement-chain):
// graph codegen types a nullable `Timestamp`, `Int8`, `Int` or `Boolean`
// setter by its value type (`set x(value: i64)`), and AssemblyScript compiles a
// `null` in a value-type position to 0 (`compileExpression`'s `NodeKind.Null`
// case, with an "unusual type" warning). graph-node stores that 0; envio used to
// throw "Cannot convert null to a BigInt" out of the save.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.1.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Gateway
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Gateway
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities:
        - History
      abis:
        - name: Gateway
          file: ./abis/Gateway.json
      eventHandlers:
        - event: Deposit(uint256)
          handler: handleDeposit
      file: ./src/gateway.ts
`,
  ~schema=`
type History @entity(immutable: true) {
  id: ID!
  withdrawableTimestamp: Timestamp
  sequence: Int8
  attempts: Int
  settled: Boolean
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Gateway.json",
      `[{"type":"event","name":"Deposit","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "generated/schema.ts",
      `
import { Entity, Value, ValueKind, store } from "@graphprotocol/graph-ts";

export class History extends Entity {
  constructor(id: string) {
    super();
    this.set("id", Value.fromString(id));
  }

  save(): void {
    store.set("History", this.get("id")!.toString(), this);
  }

  set withdrawableTimestamp(value: i64) {
    this.set("withdrawableTimestamp", Value.fromTimestamp(value));
  }

  set sequence(value: i64) {
    this.set("sequence", Value.fromI64(value));
  }

  set attempts(value: i32) {
    this.set("attempts", Value.fromI32(value));
  }

  set settled(value: boolean) {
    this.set("settled", Value.fromBoolean(value));
  }
}
`,
    ),
    (
      "src/gateway.ts",
      `
import { History } from "../generated/schema";

export function handleDeposit(event: any): void {
  const history = new History("h1");
  history.withdrawableTimestamp = null;
  history.sequence = null;
  history.attempts = null;
  history.settled = null;
  history.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a null assigned to a value-typed setter", () => {
  it("is stored as AssemblyScript's zero", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Gateway", event: "Deposit", params: { amount: 1n } }] },
      },
    });

    t.expect(await indexer.History.getOrThrow("h1")).toEqual({
      id: "h1",
      withdrawableTimestamp: new Date(0),
      sequence: 0n,
      attempts: 0,
      settled: false,
    });
  });
});
`,
)
