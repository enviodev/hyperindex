// AssemblyScript accepts a name imported twice, and Quickswap's farming
// mappings import the same generated event class from two contracts' bindings.
// JavaScript refuses a module that declares the binding twice.
let farmedEvent = `
import { ethereum, BigInt } from "@graphprotocol/graph-ts";

export class Farmed extends ethereum.Event {
  get params(): Farmed__Params {
    return new Farmed__Params(this);
  }
}

export class Farmed__Params {
  _event: Farmed;

  constructor(event: Farmed) {
    this._event = event;
  }

  get amount(): BigInt {
    return this._event.parameters[0].value.toBigInt();
  }
}
`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: EternalFarming
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: EternalFarming
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Farm
      abis:
        - name: EternalFarming
          file: ./abis/Farming.json
      eventHandlers:
        - event: Farmed(uint256)
          handler: handleFarmed
      file: ./src/farming.ts
`,
  ~schema=`
type Farm @entity {
  id: ID!
  amount: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Farming.json",
      `[{"type":"event","name":"Farmed","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    ("generated/EternalFarming/EternalFarming.ts", farmedEvent),
    ("generated/LimitFarming/LimitFarming.ts", farmedEvent),
    (
      "src/farming.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { Farmed } from "../generated/EternalFarming/EternalFarming";
import { Farmed } from "../generated/LimitFarming/LimitFarming";

export function handleFarmed(event: Farmed): void {
  let farm = new Entity();
  farm.setBigInt("amount", event.params.amount);
  store.set("Farm", "f", farm);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a class imported from two generated modules", () => {
  it("loads and runs the mapping", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: { 1: { simulate: [{ contract: "EternalFarming", event: "Farmed", params: { amount: 7n } }] } },
    });

    t.expect(await indexer.Farm.getAll()).toEqual([{ id: "f", amount: 7n }]);
  });
});
`,
)
