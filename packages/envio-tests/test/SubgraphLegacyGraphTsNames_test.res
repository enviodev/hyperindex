// graph-ts before 0.18 (apiVersion 0.0.3 and older) exported its Ethereum
// classes at the top level: `EthereumBlock`, `EthereumEvent`, `EthereumValue`,
// `SmartContract`, ... — `ethereum.Block` and friends since. Mappings of that
// age (blocklytics' ethereum-blocks: `handleBlock(block: EthereumBlock)`) and the
// generated code graph-cli 0.17 committed beside them (`extends EthereumEvent`)
// import those names, and the shim exported none of them.
let manifest = `
specVersion: 0.0.2
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.3
      language: wasm/assemblyscript
      entities:
        - Owner
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`

let schema = `
type Owner @entity {
  id: ID!
  node: BigInt!
  block: BigInt!
  kinds: String!
}
`

let abi = `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"node","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Registry.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Registry.json", abi),
    // graph-cli 0.17's output, committed.
    (
      "src/types/Registry/Registry.ts",
      `
import {
  EthereumCall,
  EthereumEvent,
  SmartContract,
  EthereumValue,
  JSONValue,
  TypedMap,
  Entity,
  EthereumTuple,
  Bytes,
  Address,
  BigInt,
  CallResult
} from "@graphprotocol/graph-ts";

export class NewOwner extends EthereumEvent {
  get params(): NewOwner__Params {
    return new NewOwner__Params(this);
  }
}

export class NewOwner__Params {
  _event: NewOwner;

  constructor(event: NewOwner) {
    this._event = event;
  }

  get node(): BigInt {
    return this._event.parameters[0].value.toBigInt();
  }
}

export class Registry extends SmartContract {
  static bind(address: Address): Registry {
    return new Registry("Registry", address);
  }
}
`,
    ),
    (
      "src/types/schema.ts",
      `
import { Entity, Value, store, BigInt } from "@graphprotocol/graph-ts";

export class Owner extends Entity {
  constructor(id: string) {
    super();
    this.set("id", Value.fromString(id));
  }

  save(): void {
    store.set("Owner", this.get("id").toString(), this);
  }

  set node(value: BigInt) {
    this.set("node", Value.fromBigInt(value));
  }

  set block(value: BigInt) {
    this.set("block", Value.fromBigInt(value));
  }

  set kinds(value: string) {
    this.set("kinds", Value.fromString(value));
  }
}
`,
    ),
    (
      "src/registry.ts",
      `
import {
  EthereumBlock,
  EthereumEvent,
  EthereumTransaction,
  EthereumValue,
  EthereumValueKind,
  EthereumTuple,
  BigInt,
} from "@graphprotocol/graph-ts";
import { NewOwner } from "./types/Registry/Registry";
import { Owner } from "./types/schema";

function blockOf(event: EthereumEvent): EthereumBlock {
  return event.block;
}

export function handleNewOwner(event: NewOwner): void {
  let tx: EthereumTransaction = event.transaction;
  let tuple = new EthereumTuple();
  tuple.push(EthereumValue.fromI32(7));
  let owner = new Owner(event.params.node.toString());
  owner.node = event.params.node;
  owner.block = blockOf(event).number;
  owner.kinds =
    (tuple[0].kind == EthereumValueKind.INT ? "int" : "other") + "/" + (tx != null ? "tx" : "none");
  owner.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("graph-ts names from before ethereum.*", () => {
  it("resolve to the shim's classes", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { node: 5n }, block: { number: 12 } }] },
      },
    });

    t.expect(await indexer.Owner.getAll()).toEqual([{ id: "5", node: 5n, block: 12n, kinds: "int/tx" }]);
  });
});
`,
)
