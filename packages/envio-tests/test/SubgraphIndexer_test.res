// A real subgraph project — manifest, schema and AssemblyScript mapping, all
// unmodified — running on HyperIndex.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Gravity
    network: mainnet
    source:
      address: "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"
      abi: Gravity
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Gravatar
      abis:
        - name: Gravity
          file: ./abis/Gravity.json
      eventHandlers:
        - event: NewGravatar(uint256,address,string)
          handler: handleNewGravatar
      file: ./src/gravity.ts
`,
  ~schema=`
type Gravatar @entity {
  id: Bytes!
  owner: Bytes!
  displayName: String!
  updates: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Gravity.json",
      `[{"type":"event","name":"NewGravatar","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false},{"name":"owner","type":"address","indexed":false},{"name":"displayName","type":"string","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/gravity.ts",
      `
import { BigInt, Bytes, Entity, store, log } from "@graphprotocol/graph-ts";

export function handleNewGravatar(event: any): void {
  let id = Bytes.fromI32(event.params.id.toI32());
  let key = id.toHexString();

  let gravatar = store.get("Gravatar", key);
  if (gravatar === null) {
    gravatar = new Entity();
    gravatar.setBigInt("updates", BigInt.fromI32(1));
  } else {
    gravatar.setBigInt("updates", gravatar.getBigInt("updates").plus(BigInt.fromI32(1)));
  }

  gravatar.setBytes("owner", event.params.owner);
  gravatar.setString("displayName", event.params.displayName);

  log.info("gravatar {}", [key]);
  store.set("Gravatar", key, gravatar);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

describe("gravatar subgraph", () => {
  it("runs the mapping and stores the entity", async (t) => {
    const indexer = createTestIndexer();
    const owner = Addresses.mockAddresses[1];

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Gravity",
              event: "NewGravatar",
              params: { id: 1n, owner, displayName: "zero" },
            },
            {
              contract: "Gravity",
              event: "NewGravatar",
              params: { id: 1n, owner, displayName: "one" },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Gravatar.getOrThrow("0x00000001")).toEqual({
      id: "0x00000001",
      owner: owner.toLowerCase(),
      displayName: "one",
      updates: 2n,
    });
  });
});
`,
)
