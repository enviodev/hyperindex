// graph-ts' `Bytes.toString()` is graph-node's `bytes_to_string`: the bytes as
// UTF-8, trailing NULs trimmed. The shim returned hex, so Aave's
// `event.params.id.toString() == "POOL"` never held and its Pool was never
// created, and a bytes32 ERC20 symbol (MKR) was stored as `0x4d4b52…`.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Provider
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Provider
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Proxy
      abis:
        - name: Provider
          file: ./abis/Provider.json
      eventHandlers:
        - event: ProxyCreated(bytes32,address)
          handler: handleProxyCreated
      file: ./src/provider.ts
`,
  ~schema=`
type Proxy @entity {
  id: ID!
  name: String!
  isPool: Boolean!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Provider.json",
      `[{"type":"event","name":"ProxyCreated","anonymous":false,"inputs":[{"name":"id","type":"bytes32","indexed":false},{"name":"proxyAddress","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/provider.ts",
      `
import { Bytes, Entity, store } from "@graphprotocol/graph-ts";

export function handleProxyCreated(event: any): void {
  let id: Bytes = event.params.id;
  let entity = new Entity();
  entity.setString("name", id.toString());
  entity.setBoolean("isPool", id.toString() == "POOL");
  store.set("Proxy", event.params.proxyAddress.toHexString(), entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const bytes32 = (text: string) => "0x" + Buffer.from(text, "utf8").toString("hex").padEnd(64, "0");
const pool = "0x2222222222222222222222222222222222222222";
const configurator = "0x3333333333333333333333333333333333333333";

describe("Bytes.toString()", () => {
  it("reads the bytes as UTF-8 with the trailing NULs trimmed", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Provider", event: "ProxyCreated", params: { id: bytes32("POOL"), proxyAddress: pool } },
            {
              contract: "Provider",
              event: "ProxyCreated",
              params: { id: bytes32("POOL_CONFIGURATOR"), proxyAddress: configurator },
            },
          ],
        },
      },
    });

    t.expect((await indexer.Proxy.getAll()).sort((a: any, b: any) => a.id.localeCompare(b.id))).toEqual([
      { id: pool, name: "POOL", isPool: true },
      { id: configurator, name: "POOL_CONFIGURATOR", isPool: false },
    ]);
  });
});
`,
)
