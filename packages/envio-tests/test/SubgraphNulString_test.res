// graph-node drops every NUL from a string that reaches the store
// (`FromAscObj<AscString> for String`: "Strip null characters since they are not
// accepted by Postgres"). Spectra stored a bytes32 symbol decoded as a string,
// and Postgres rejected the write with `invalid byte sequence 0x00`.
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
  aliases: [String!]!
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
import { Bytes, Entity, Value, store } from "@graphprotocol/graph-ts";

export function handleProxyCreated(event: any): void {
  let id: Bytes = event.params.id;
  let entity = new Entity();
  let nul = String.fromCharCode(0);
  entity.setString("name", "PO" + nul + "OL" + nul);
  entity.set("aliases", Value.fromStringArray(["A" + nul + "B", "C"]));
  store.set("Proxy", event.params.proxyAddress.toHexString() + nul, entity);
  // The id is stripped on the read too: the same entity is found without the NUL.
  let again = store.get("Proxy", event.params.proxyAddress.toHexString())!;
  again.setString("name", "POOL");
  store.set("Proxy", event.params.proxyAddress.toHexString() + nul, again);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const bytes32 = (text: string) => "0x" + Buffer.from(text, "utf8").toString("hex").padEnd(64, "0");
const pool = "0x2222222222222222222222222222222222222222";

describe("NUL in a string field", () => {
  it("is dropped before the write, as graph-node does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Provider", event: "ProxyCreated", params: { id: bytes32("POOL"), proxyAddress: pool } },
          ],
        },
      },
    });

    t.expect(await indexer.Proxy.getAll()).toEqual([{ id: pool, name: "POOL", aliases: ["AB", "C"] }]);
  });
});
`,
)
