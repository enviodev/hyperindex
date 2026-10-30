// A data source with no `source.address` matches the events of every contract
// on graph-node — ENS's `Resolver` is the case: one data source for every
// resolver anyone deploys. Translated as an address-less contract with nothing
// to register its addresses, it never matched anything, and every one of its
// handlers silently ran zero times. Its `dataSource.address()` is empty, as
// graph-node's DataSourceDetails holds `ds.address().unwrap_or_default()`; the
// emitter is `event.address`.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
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
        - Addr
      abis:
        - name: Resolver
          file: ./abis/Resolver.json
      eventHandlers:
        - event: AddrChanged(indexed bytes32,address)
          handler: handleRegistryAddr
      file: ./src/resolver.ts
  - kind: ethereum/contract
    name: Resolver
    network: mainnet
    source:
      abi: Resolver
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Addr
      abis:
        - name: Resolver
          file: ./abis/Resolver.json
      eventHandlers:
        - event: AddrChanged(indexed bytes32,address)
          handler: handleAddrChanged
      file: ./src/resolver.ts
`,
  ~schema=`
type Addr @entity {
  id: ID!
  resolver: String!
  a: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Resolver.json",
      `[{"type":"event","name":"AddrChanged","anonymous":false,"inputs":[{"name":"node","type":"bytes32","indexed":true},{"name":"a","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/resolver.ts",
      `
import { Entity, dataSource, store } from "@graphprotocol/graph-ts";

function save(prefix: string, event: any): void {
  let entity = new Entity();
  entity.setString("resolver", dataSource.address().toHexString());
  entity.setString("a", event.params.a.toHexString());
  store.set("Addr", prefix + ":" + event.address.toHexString(), entity);
}

export function handleAddrChanged(event: any): void {
  save("any", event);
}

export function handleRegistryAddr(event: any): void {
  save("registry", event);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const node = "0x" + "ab".repeat(32);
const a = "0x3333333333333333333333333333333333333333";

describe("a data source without an address", () => {
  it("runs its handlers for an event of any contract", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Resolver",
              event: "AddrChanged",
              srcAddress: "0x4444444444444444444444444444444444444444",
              params: { node, a },
              block: { number: 10 },
            },
            {
              contract: "Resolver",
              event: "AddrChanged",
              srcAddress: "0x5555555555555555555555555555555555555555",
              params: { node, a },
              block: { number: 11 },
            },
          ],
        },
      },
    });

    t.expect((await indexer.Addr.getAll()).sort((x, y) => x.id.localeCompare(y.id))).toEqual([
      {
        id: "any:0x4444444444444444444444444444444444444444",
        resolver: "0x",
        a,
      },
      {
        id: "any:0x5555555555555555555555555555555555555555",
        resolver: "0x",
        a,
      },
    ]);
  });

  it("leaves a data source with an address bound to it", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [{ contract: "Registry", event: "AddrChanged", params: { node, a }, block: { number: 11 } }],
        },
      },
    });
    t.expect(await indexer.Addr.getAll()).toEqual([
      {
        id: "registry:0x1111111111111111111111111111111111111111",
        resolver: "0x1111111111111111111111111111111111111111",
        a,
      },
    ]);

    const elsewhere = createTestIndexer();
    await t
      .expect(
        elsewhere.process({
          chains: {
            1: {
              startBlock: 0,
              endBlock: 100,
              simulate: [
                {
                  contract: "Registry",
                  event: "AddrChanged",
                  srcAddress: "0x6666666666666666666666666666666666666666",
                  params: { node, a },
                  block: { number: 10 },
                },
              ],
            },
          },
        }),
      )
      .rejects.toThrow(/never reached a handler/);
  });
});
`,
)
