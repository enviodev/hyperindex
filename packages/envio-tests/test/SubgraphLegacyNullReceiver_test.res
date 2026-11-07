// graph-node does not null-check an AssemblyScript pointer below apiVersion
// 0.0.5: a method on a null BigInt reads an empty BigInt (zero) -- Ribbon's
// `premiumEarned.plus(x)` on a field nothing set -- and a field read through a
// null reference reads zero -- vintage-v3's `new Array<Def>(6)` holes. From
// 0.0.5 the same code traps, so it still fails there.
let manifest = apiVersion =>
  `
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
      apiVersion: ${apiVersion}
      language: wasm/assemblyscript
      entities:
        - Order
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`

let schema = `
type Order @entity {
  id: ID!
  premium: BigInt!
  fee: BigDecimal!
  text: String!
  hit: String!
}
`

let files = Dict.fromArray([
  (
    "abis/Registry.json",
    `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
  ),
])

let mappings = Dict.fromArray([
  (
    "src/registry.ts",
    `
import { Address, BigDecimal, BigInt, Entity, store, Value } from "@graphprotocol/graph-ts";

class Definition {
  address: Address;
  constructor(address: Address) {
    this.address = address;
  }
}

function nothing(): BigInt | null {
  return null;
}

function nothingDecimal(): BigDecimal | null {
  return null;
}

export function handleNewOwner(event: any): void {
  let premium = nothing().plus(BigInt.fromI32(90086)).plus(nothing());
  let fee = nothingDecimal().plus(BigDecimal.fromString("1.5"));
  let definitions = new Array<Definition>(2);
  definitions.push(new Definition(Address.fromString("0x0000000000000000000000000000000000000002")));
  let hit = "none";
  for (let i = 0; i < definitions.length; i++) {
    let definition = definitions[i];
    if (definition.address.toHexString() == "0x0000000000000000000000000000000000000002") {
      hit = "found";
    }
  }
  let order = new Entity();
  order.set("id", Value.fromString("o1"));
  order.set("premium", Value.fromBigInt(premium));
  order.set("fee", Value.fromBigDecimal(fee));
  order.set("text", Value.fromString(nothing().toString()));
  order.set("hit", Value.fromString(hit));
  store.set("Order", "o1", order);
}
`,
  ),
])

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=manifest("0.0.4"),
  ~schema,
  ~files,
  ~mappings,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a null receiver under apiVersion 0.0.4", () => {
  it("reads as zero, and a hole in an array reads as nothing", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 1n } }] },
      },
    });

    const order = await indexer.Order.getOrThrow("o1");
    t.expect({ ...order, fee: order.fee.toString() }).toEqual({
      id: "o1",
      premium: 90086n,
      fee: "1.5",
      text: "0",
      hit: "found",
    });
  });
});
`,
)
