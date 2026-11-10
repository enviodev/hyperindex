// `changetype<ByteArray>(someUint8Array)` is a free reinterpret in
// AssemblyScript and an identity cast here, so the result reaches the mapping
// without ByteArray's methods. ENS's byteArrayFromHex helper — copied into a lot
// of subgraphs — is written exactly that way.
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
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Label
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NameRenewed(uint256)
          handler: handleNameRenewed
      file: ./src/registry.ts
`,
  ~schema=`
type Label @entity {
  id: ID!
  hex: String!
  hashed: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NameRenewed","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/registry.ts",
      `
import { BigInt, ByteArray, Entity, crypto, store } from "@graphprotocol/graph-ts";

function byteArrayFromHex(s: string): ByteArray {
  let out = new Uint8Array(s.length / 2);
  for (let i = 0; i < s.length; i += 2) {
    out[i / 2] = parseInt(s.substring(i, i + 2), 16) as u32;
  }
  return changetype<ByteArray>(out);
}

function uint256ToByteArray(i: BigInt): ByteArray {
  let hex = i.toHex().slice(2).padStart(64, "0");
  return byteArrayFromHex(hex);
}

export function handleNameRenewed(event: any): void {
  let label = uint256ToByteArray(event.params.id);

  let entity = new Entity();
  entity.setString("hex", label.toHex());
  entity.setString("hashed", crypto.keccak256(label).toHex());
  store.set("Label", "label", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("changetype to a graph-ts class", () => {
  it("leaves the reinterpreted value usable as one", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [{ contract: "Registry", event: "NameRenewed", params: { id: 255n } }],
        },
      },
    });

    t.expect(await indexer.Label.getOrThrow("label")).toEqual({
      id: "label",
      hex: "0x00000000000000000000000000000000000000000000000000000000000000ff",
      hashed: "0xe08ec2af2cfc251225e1968fd6ca21e4044f129bffa95bac3503be8bdb30a367",
    });
  });
});
`,
)
