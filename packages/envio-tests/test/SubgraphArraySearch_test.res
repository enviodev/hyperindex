// AssemblyScript's Array#includes, indexOf and lastIndexOf compare elements
// with `==`, which for graph-ts' BigInt, BigDecimal and Bytes is the
// overloaded value comparison. JavaScript's compare identity, so ENS's
// handleMulticoinAddrChanged (`if (!coinTypes.includes(coinType))`) pushed
// a second "60" onto Resolver.coinTypes where graph-node keeps one.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Resolver
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Resolver
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Resolver
      abis:
        - name: Resolver
          file: ./abis/Resolver.json
      eventHandlers:
        - event: AddressChanged(indexed bytes32,uint256,bytes)
          handler: handleAddressChanged
      file: ./src/resolver.ts
`,
  ~schema=`
type Resolver @entity {
  id: ID!
  coinTypes: [BigInt!]
  searches: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Resolver.json",
      `[{"type":"event","name":"AddressChanged","anonymous":false,"inputs":[{"name":"node","type":"bytes32","indexed":true},{"name":"coinType","type":"uint256","indexed":false},{"name":"newAddress","type":"bytes","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/resolver.ts",
      `
import { Address, BigDecimal, BigInt, Bytes, Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleAddressChanged(event: any): void {
  let id = event.params.node.toHexString();
  let resolver = store.get("Resolver", id);
  if (resolver == null) resolver = new Entity();
  let stored = resolver.get("coinTypes");
  let coinTypes = stored == null ? new Array<BigInt>() : stored.toBigIntArray();
  let coinType: BigInt = event.params.coinType;
  if (!coinTypes.includes(coinType)) coinTypes.push(coinType);
  resolver.set("coinTypes", Value.fromBigIntArray(coinTypes));

  let owners = [Address.fromString("0x2222222222222222222222222222222222222222"), Address.fromString("0x3333333333333333333333333333333333333333")];
  let prices = [BigDecimal.fromString("1.5"), BigDecimal.fromString("2")];
  let words = ["a", "b", "a"];
  let searches: string[] = [
    owners.indexOf(Address.fromString("0x3333333333333333333333333333333333333333")).toString(),
    owners.includes(Address.fromBytes(Bytes.fromHexString("0x2222222222222222222222222222222222222222"))) ? "yes" : "no",
    prices.lastIndexOf(BigDecimal.fromString("1.50")).toString(),
    coinTypes.indexOf(BigInt.fromI32(60), 1).toString(),
    words.lastIndexOf("a").toString(),
    "envio".includes("vi") ? "yes" : "no",
  ];
  resolver.setString("searches", searches.join(","));
  store.set("Resolver", id, resolver);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const node = "0x" + "aa".repeat(32);

describe("an array search", () => {
  it("compares graph-ts values the way AssemblyScript's == does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            { contract: "Resolver", event: "AddressChanged", params: { node, coinType: 60n, newAddress: "0x01" }, block: { number: 10 } },
            { contract: "Resolver", event: "AddressChanged", params: { node, coinType: 60n, newAddress: "0x02" }, block: { number: 11 } },
            { contract: "Resolver", event: "AddressChanged", params: { node, coinType: 0n, newAddress: "0x03" }, block: { number: 12 } },
          ],
        },
      },
    });
    t.expect(await indexer.Resolver.getAll()).toEqual([
      { id: node, coinTypes: [60n, 0n], searches: "1,yes,0,-1,2,yes" },
    ]);
  });
});
`,
)
